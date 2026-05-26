---
name: perfia
description: Activate, upgrade, test, and benchmark the 4-tool token-saving stack (context-mode, claude-mem, RTK, caveman). Reports per-tool + global token savings and detects conflicts that would erase the gains.
trigger: /perfia
---

# /perfia — Performance IA stack manager

Manages the 4 complementary token-saving tools:

| Tool         | Layer                       | Plugin slug                       | CLI / hook        |
| ------------ | --------------------------- | --------------------------------- | ----------------- |
| context-mode | MCP — data offload + memory | `context-mode@context-mode`       | MCP only          |
| claude-mem   | session memory + compaction | `claude-mem@thedotmack`           | `claude-mem` CLI  |
| RTK          | bash output compression     | (CLI only, hook in `~/.claude`)   | `rtk` (Rust)      |
| caveman      | response-style compression  | `caveman@caveman`                 | hook              |

## Usage

```
/perfia            # default → status
/perfia status     # current state of the 4 tools (read-only)
/perfia activate   # install missing + enable disabled (asks confirmation)
/perfia upgrade    # bump each to latest (asks confirmation)
/perfia test       # ping each one-by-one, verify it actually responds
/perfia gain       # per-tool + global token-savings report
/perfia check      # conflict detector — verifies the 4 are complementary
/perfia doctor     # full pipeline: status → test → check → gain
```

## Routing

Read the args after `/perfia`. If empty, treat as `status`. Always print a one-line header `# /perfia <subcommand>` before running so the user sees which path you took.

---

## Subcommand: status

Run `bash ~/.claude/skills/perfia/scripts/status.sh` and report its output verbatim. The script returns exit code `0` if all 4 are healthy, `1` if any is missing/disabled.

If exit code is `1`, end with a single line: `→ Run \`/perfia activate\` to fix.` (do not auto-fix from `status`).

## Subcommand: activate

Two phases — detect, then fix with confirmation.

**Phase 1 — detect.** Run `bash ~/.claude/skills/perfia/scripts/status.sh`. Parse which of the 4 are in state `not-installed` or `installed-disabled`.

**Phase 2 — fix.** If any are unhealthy, use `AskUserQuestion` to confirm the fix plan. Example phrasing:

> "claude-mem is installed but disabled, caveman is not installed. Apply the following fixes? [Yes / No / Show me commands first]"

On `Yes`, run for each tool:

- `claude-mem` disabled → `claude plugin enable claude-mem@thedotmack`
- `caveman` not installed → `claude plugin install caveman@caveman` then `claude plugin enable caveman@caveman`
- `context-mode` disabled → `claude plugin enable context-mode@context-mode`
- `rtk` hook missing → `rtk init -g` (only run this if `rtk gain` output said `[warn] No hook installed`). The CLI is interactive and defaults to `N` in non-interactive shells; after running it, manually patch `~/.claude/settings.json` to add a `hooks.PreToolUse` entry pointing at `~/.claude/hooks/rtk-rewrite.sh`.

**Gotcha discovered 2026-05-18**: the *first* call to `claude plugin enable` on any plugin creates `enabledPlugins` in `~/.claude/settings.json` and **clobbers** plugins that were enabled implicitly at the marketplace level. Mitigation: after EVERY enable/install, snapshot the full `claude plugin list --json` and re-enable any plugin that flipped from `enabled:true` to `enabled:false`. The `activate` flow must do this snapshot-and-restore.

After every fix, re-run `status.sh` and report the new state. If anything is still red, surface it explicitly — do not pretend success.

## Subcommand: upgrade

Two phases: detect, then confirm + apply.

**Phase 1 — collect current vs latest.** Run `bash ~/.claude/skills/perfia/scripts/check-updates.sh --force` so the cache is fresh. The script:

- Refreshes Claude marketplaces (`claude plugin marketplace update`) — non-fatal on network failure.
- Reads installed plugin versions from `claude plugin list --json`.
- Reads latest plugin versions from each marketplace's `marketplace.json`. Falls back to the marketplace clone's short git SHA (12 chars) when no `version` field exists — caveman is SHA-versioned.
- For RTK: parses `cargo install --list` to detect path-installed dev builds; latest = `Cargo.toml` `version` on the tracked upstream branch (`git fetch` + `git show origin/<branch>:Cargo.toml`). Skips the public `cargo search rtk` registry — the public crate name belongs to a different project (Rust Type Kit) and gives wrong numbers.
- Writes `~/.claude/perfia/upgrade-check.json` and exits `0` if all up-to-date, `2` if any update available.

**Phase 2 — confirm + upgrade.** Read the cache, show a table `<tool>: <current> → <latest>` (skip tools already up-to-date), and use `AskUserQuestion` to confirm. On `Yes`:

- Plugins: `claude plugin update <slug>` per tool with an update. Restart is required for the new version to load.
- RTK (path-installed): `cd <repo_path> && git pull && cargo install --path . --force`. Discover `<repo_path>` from `cargo install --list` (line `rtk vX.Y.Z (<repo_path>):`).
- RTK (registry-installed, rare): `cargo install rtk --force` — only if `cargo install --list` shows no path.

After upgrade, re-run `check-updates.sh --force` then `status` so the version columns reflect the new state.

**Passive surfacing.** `/perfia status` calls `check-updates.sh --quiet` at the end (uses the 24h cache, no network unless stale). If any update is available, status appends an `updates available (N):` block and a `→ Run /perfia upgrade to apply.` line. The user is never auto-upgraded — the trigger is always explicit. This matches the security principle of pinning versions: drift is reported, not silently applied.

## Subcommand: test

Run `bash ~/.claude/skills/perfia/scripts/status.sh --test`. For each of the 4 tools, the script issues a minimal end-to-end ping:

- **context-mode**: call the `ctx_stats` MCP tool. Alive iff it returns a JSON-shaped reply.
- **claude-mem**: `claude-mem --version` exits 0.
- **RTK**: `rtk --version` exits 0 AND `rtk gain` returns non-empty stats.
- **caveman**: `test -d ~/.claude/plugins/cache/caveman/caveman/*/skills/caveman` AND the plugin appears in `claude plugin list`.

Report a table `<tool> | alive | version | latency_ms`. **Do not infer aliveness from "the plugin is enabled" — actually run the ping.**

`ctx_stats` for context-mode is the only one that requires an MCP tool call rather than shell — when you reach context-mode, invoke the `ctx_stats` MCP tool directly and inline the result.

## Subcommand: gain

This is the main report. Two parts: per-tool, then global.

Run `bash ~/.claude/skills/perfia/scripts/gain.sh`. It aggregates from:

| Tool         | Source of truth                                                |
| ------------ | -------------------------------------------------------------- |
| RTK          | `rtk gain` (parse `Tokens saved:` line + per-command table)    |
| context-mode | `ctx_stats` MCP tool (KB stored × 0.25 = approx tokens saved)  |
| claude-mem   | `~/.claude/perfia/gain.jsonl` (entries with `tool=claude-mem`) |
| caveman      | `~/.claude/perfia/gain.jsonl` (entries with `tool=caveman`)    |

For `context-mode`: invoke the `ctx_stats` MCP tool and parse the `total_size_kb` field, multiply by `1024 / TOKEN_CHARS_PER_TOKEN` (~4) to estimate tokens kept out of the context window.

**Output format** (render in the response, do not write to a file):

```
# /perfia gain — token savings

Per tool
─────────────────────────────────────
  RTK            44.7M tokens (68.3%)   18956 commands
  context-mode    X.XM tokens (~est.)   N entries indexed
  claude-mem      X.XM tokens (~est.)   N compactions logged
  caveman         X.XM tokens (~est.)   N compressions logged
─────────────────────────────────────
  TOTAL          XX.XM tokens saved

Complementary check: <PASS|WARN|FAIL>   ← from check.sh
  - <one line per detected conflict, or "no conflicts">
```

If the complementary check is `FAIL`, prefix the TOTAL line with `⚠️` and add `effective gain may be lower than reported — see /perfia check`. The user MUST not be told they're winning when two tools are double-processing the same buffer.

If `~/.claude/perfia/gain.jsonl` does not exist, claude-mem and caveman columns show `N/A — install gain hook via /perfia activate`. Do not fabricate numbers.

## Subcommand: check

Run `bash ~/.claude/skills/perfia/scripts/check.sh`. The script encodes the following conflict rules:

### Rule R1 — bash interception double-hook

Both RTK and context-mode want bash output. If RTK's hook is installed (`grep -l "rtk " ~/.claude/hooks/*.sh ~/.claude/settings.json 2>/dev/null`) AND context-mode's bash-redirect rule is active (CLAUDE.md mentions `ctx_batch_execute` as the bash override) → check the ordering documented in their respective configs. Conflict if both claim to wrap the same command (`git`, `grep`, etc.).

### Rule R2 — memory source overlap

context-mode session memory (`ctx_search(source: "compaction"|"user-prompt"|...)`) and claude-mem session compaction both fight for the same "recall after /clear" job. If both write to a project's memory and they don't share a registry, recall queries can miss data stored by the other. Conflict iff both are enabled AND `claude-mem` writes to a path other than `~/.claude/projects/<slug>/memory/`.

### Rule R3 — output compression layering

caveman compresses Claude's responses; RTK compresses tool outputs. They operate on different buffers and are complementary — no conflict expected. Verify by listing each tool's compression target. Flag if they ever overlap (e.g., if RTK ever rewrites the LLM response stream).

### Rule R4 — version drift

If any of the 4 is more than one minor version behind its latest, report as `WARN`. Old context-mode (< 1.0.107) lacks the `ctx_search` source filter; old RTK (< 0.29) double-counted some commands; etc.

Output format:

```
# /perfia check

R1 bash double-hook       : <PASS|WARN|FAIL>  <evidence>
R2 memory source overlap  : <PASS|WARN|FAIL>  <evidence>
R3 output compression     : <PASS|WARN|FAIL>  <evidence>
R4 version drift          : <PASS|WARN|FAIL>  <evidence>

Verdict: <COMPLEMENTARY|DEGRADED|CONFLICT>
```

`<evidence>` must cite an actual path or value (e.g., `~/.claude/settings.json:hooks[0]` or `claude-mem v12.1.4 vs latest 12.1.4`). No vague "looks fine" — show the bytes.

## Subcommand: doctor

Run, in order: `status` → `test` → `check` → `gain`. Print each section's header, run the corresponding subcommand, collect the result, and end with a one-line verdict:

```
Verdict: <ALL GREEN | ATTENTION NEEDED — see <section>>
```

Stop at the first `FAIL` if the user typed `/perfia doctor --strict`; otherwise run all four sections regardless.

---

## Gain-telemetry hook (installable)

claude-mem and caveman expose no native gain numbers. `~/.claude/skills/perfia/scripts/perfia-gain-hook.sh` is a wrapper that the user can install (via `/perfia activate`) which logs `{tool, ts, bytes_in, bytes_out}` to `~/.claude/perfia/gain.jsonl` whenever those tools run. **Never install the hook without explicit user confirmation** — it modifies global hook config.

---

## Self-check before reporting back

After any subcommand:

1. Did every CLI call return exit code 0? If not, surface the failure — do not silently swallow.
2. Did you actually call `ctx_stats` (MCP tool), or did you skip context-mode because shell scripts can't reach it? Calling it is mandatory whenever the subcommand needs context-mode numbers.
3. Are the numbers you printed derived from real telemetry, or fabricated? If telemetry is missing (e.g., gain.jsonl empty), say `N/A`, not `0`.
4. Did you propose any auto-fix without asking via `AskUserQuestion`? That's a bug — every fix path goes through confirmation.
