---
name: tokenwar
description: Activate, upgrade, test, and benchmark the 5-tool token-saving stack (context-mode, claude-mem, RTK, caveman, ponytail). Reports per-tool + per-provider (Codex, Gemini, Kimi) token savings and detects conflicts that would erase the gains.
trigger: /tokenwar
---

# /tokenwar — token-saving stack manager

Manages the 5 complementary token-saving tools:

| Tool         | Layer                       | Plugin slug                       | CLI / hook        |
| ------------ | --------------------------- | --------------------------------- | ----------------- |
| context-mode | MCP — data offload + memory | `context-mode@context-mode`       | MCP only          |
| claude-mem   | session memory + compaction | `claude-mem@thedotmack`           | `claude-mem` CLI  |
| RTK          | bash output compression     | (CLI only, hook in `~/.claude`)   | `rtk` (Rust)      |
| caveman      | response-style compression  | `caveman@caveman`                 | hook              |
| ponytail     | the code the LLM writes     | `ponytail@ponytail`               | plugin (mode-gated) |

> ponytail and caveman are **presence-only** (a ruleset / a style nudge — no metered buffer): `status` and `activate` manage all five, but the conflict detector (`check`) and the auto-update tracker cover only the four buffer-owning, version-tracked tools. ponytail upgrades via `claude plugin update ponytail@ponytail`, and is toggled per-session with `/ponytail off|lite|full|ultra`.

## Multi-provider support

tokenwar now tracks token usage across AI coding agents, each from its own
**native telemetry** — never fabricated:

| Provider     | Telemetry source                                | Token data            |
| ------------ | ----------------------------------------------- | --------------------- |
| Claude Code  | RTK (`rtk gain`) + context-mode + claude-mem    | per-command + monthly |
| Codex        | `~/.codex/state_5.sqlite` → `threads.tokens_used` | per-session + monthly |
| Gemini CLI   | N/A (server-side sessions — no local store)      | —                     |
| Kimi Code CLI | N/A (`~/.kimi-code` has no documented token store) | —                  |

Each provider's token counts are valued at their own list prices (input-side).
Provider prices are defined in `scripts/lib/providers.sh` — verify against
official pricing pages.

## Cross-CLI status (Claude vs Codex/Gemini/Kimi)

The persistent **status bar** is a Claude Code feature (its `statusLine` API).
Codex, Gemini, and Kimi do **not** expose a status-bar API — their footers are
hardcoded in their TUIs, and their hooks only inject into the *model* context,
never the screen. So tokenwar surfaces the stack differently per CLI:

| CLI        | How the stack is surfaced                                              |
| ---------- | --------------------------------------------------------------------- |
| Claude Code | Native persistent bottom bar via `statusLine` (auto, always visible)  |
| Codex      | **Launch banner** + reminder + upgrade prompt (via shell wrapper)     |
| Gemini CLI | **Launch banner** + reminder + upgrade prompt (via shell wrapper)     |
| Kimi Code CLI | **Launch banner** + reminder + upgrade prompt (via shell wrapper)  |

`install.sh` wires four shell functions (one-time, then zero effort):

- `tokenwar <cmd>` — the dispatcher; `tokenwar status` / `gain` / `check` /
  `upgrade` work in **any** shell (Codex, Gemini, Kimi, plain terminal).
- `codex` / `gemini` / `kimi` — wrapped so that launching any of them prints
  the tokenwar banner (`scripts/tokenwar-launch.sh`), reminds the user to run
  `tokenwar status`, and — if the throttled cache shows pending updates —
  offers an inline **"Upgrade now? [y/N]"** that runs `scripts/upgrade.sh` for
  the 4 tools. The banner is silent for non-interactive launches
  (`codex exec`, `gemini -p …`, `kimi -p …`, pipes) so it never pollutes
  scripted output.

## Usage

```
/tokenwar            # default → status
/tokenwar status     # current state of the 5 tools (read-only)
/tokenwar activate   # install missing + enable disabled (asks confirmation)
/tokenwar upgrade    # bump each to latest (asks confirmation)
/tokenwar test       # ping each one-by-one, verify it actually responds
/tokenwar gain       # per-tool + global token-savings report
/tokenwar check      # conflict detector — verifies the 4 are complementary
/tokenwar doctor     # full pipeline: status → test → check → gain
```

## Routing

Read the args after `/tokenwar`. If empty, treat as `status`. Always print a one-line header `# /tokenwar <subcommand>` before running so the user sees which path you took.

---

## Subcommand: status

Run `bash ~/.claude/skills/tokenwar/scripts/status.sh` and report its output verbatim. The script returns exit code `0` if all 5 are healthy, `1` if any is missing/disabled.

If exit code is `1`, end with a single line: `→ Run \`/tokenwar activate\` to fix.` (do not auto-fix from `status`).

## Subcommand: activate

Two phases — detect, then fix with confirmation.

**Phase 1 — detect.** Run `bash ~/.claude/skills/tokenwar/scripts/status.sh`. Parse which of the 5 are in state `not-installed` or `installed-disabled`.

**Phase 2 — fix.** If any are unhealthy, use `AskUserQuestion` to confirm the fix plan. Example phrasing:

> "claude-mem is installed but disabled, caveman is not installed. Apply the following fixes? [Yes / No / Show me commands first]"

On `Yes`, run for each tool:

- `claude-mem` disabled → `claude plugin enable claude-mem@thedotmack`
- `caveman` not installed → `claude plugin install caveman@caveman` then `claude plugin enable caveman@caveman`
- `ponytail` not installed → `claude plugin marketplace add DietrichGebert/ponytail` (upstream; `marketplace update` later to refresh), then `claude plugin install ponytail@ponytail` then `claude plugin enable ponytail@ponytail`. The install is SHA-locked in `~/.claude/plugins/installed_plugins.json` (same as caveman), so it is pinned to the resolved commit, not a floating ref. ponytail defaults to `full` mode; `/ponytail off` turns it off per-session.
- `context-mode` disabled → `claude plugin enable context-mode@context-mode`
- `rtk` hook missing → `rtk init -g` (only run this if `rtk gain` output said `[warn] No hook installed`). The CLI is interactive and defaults to `N` in non-interactive shells; after running it, manually patch `~/.claude/settings.json` to add a `hooks.PreToolUse` entry pointing at `~/.claude/hooks/rtk-rewrite.sh`.

**One-shot alternative**: `install.sh --all` (or `curl … | bash -s -- --all`) installs the whole stack at install time — the 4 plugins (marketplace-add + install + enable, with the anti-clobber re-enable) AND the RTK binary (via rtk's official prebuilt installer — no toolchain), then wires RTK's hook with `rtk init -g`. Use `--with-plugins` or `--with-rtk` for just one half. So a fresh machine needs no separate `activate`.

**Gotcha discovered 2026-05-18**: the *first* call to `claude plugin enable` on any plugin creates `enabledPlugins` in `~/.claude/settings.json` and **clobbers** plugins that were enabled implicitly at the marketplace level. Mitigation: after EVERY enable/install, snapshot the full `claude plugin list --json` and re-enable any plugin that flipped from `enabled:true` to `enabled:false`. The `activate` flow must do this snapshot-and-restore.

After every fix, re-run `status.sh` and report the new state. If anything is still red, surface it explicitly — do not pretend success.

## Subcommand: upgrade

Two phases: detect, then confirm + apply.

**Phase 1 — collect current vs latest.** Run `bash ~/.claude/skills/tokenwar/scripts/check-updates.sh --force` so the cache is fresh. The script:

- Refreshes Claude marketplaces (`claude plugin marketplace update`) — non-fatal on network failure.
- Reads installed plugin versions from `claude plugin list --json`.
- Reads latest plugin versions from each marketplace's `marketplace.json`. Falls back to the marketplace clone's short git SHA (12 chars) when no `version` field exists — caveman is SHA-versioned.
- For RTK: parses `cargo install --list` to detect path-installed dev builds; latest = `Cargo.toml` `version` on the tracked upstream branch (`git fetch` + `git show origin/<branch>:Cargo.toml`). Skips the public `cargo search rtk` registry — the public crate name belongs to a different project (Rust Type Kit) and gives wrong numbers.
- Writes `~/.claude/tokenwar/upgrade-check.json` and exits `0` if all up-to-date, `2` if any update available.

**Phase 2 — confirm + upgrade.** Read the cache, show a table `<tool>: <current> → <latest>` (skip tools already up-to-date), and use `AskUserQuestion` to confirm. On `Yes`:

- Plugins: `claude plugin update <slug>` per tool with an update. Restart is required for the new version to load.
- RTK (path-installed): `cd <repo_path> && git pull && cargo install --path . --force`. Discover `<repo_path>` from `cargo install --list` (line `rtk vX.Y.Z (<repo_path>):`).
- RTK (registry-installed, rare): `cargo install rtk --force` — only if `cargo install --list` shows no path.

After upgrade, re-run `check-updates.sh --force` then `status` so the version columns reflect the new state.

**Passive surfacing.** `/tokenwar status` calls `check-updates.sh --quiet` at the end (uses the 24h cache, no network unless stale). If any update is available, status appends an `updates available (N):` block and a `→ Run /tokenwar upgrade to apply.` line. The user is never auto-upgraded — the trigger is always explicit. This matches the security principle of pinning versions: drift is reported, not silently applied.

## Subcommand: test

Run `bash ~/.claude/skills/tokenwar/scripts/status.sh --test`. For each of the 5 tools, the script issues a minimal end-to-end ping:

- **context-mode**: call the `ctx_stats` MCP tool. Alive iff it returns a JSON-shaped reply.
- **claude-mem**: `claude-mem --version` exits 0.
- **RTK**: `rtk --version` exits 0 AND `rtk gain` returns non-empty stats.
- **caveman**: `test -d ~/.claude/plugins/cache/caveman/caveman/*/skills/caveman` AND the plugin appears in `claude plugin list`.

Report a table `<tool> | alive | version | latency_ms`. **Do not infer aliveness from "the plugin is enabled" — actually run the ping.**

`ctx_stats` for context-mode is the only one that requires an MCP tool call rather than shell — when you reach context-mode, invoke the `ctx_stats` MCP tool directly and inline the result.

## Subcommand: gain

This is the main report. Two parts: per-tool, then global.

Run `bash ~/.claude/skills/tokenwar/scripts/gain.sh`. It aggregates from:

| Tool         | Source of truth                                                |
| ------------ | -------------------------------------------------------------- |
| RTK          | `rtk gain` (parse `Tokens saved:` line + per-command table)    |
| context-mode | `ctx_stats` MCP tool (KB stored × 0.25 = approx tokens saved)  |
| claude-mem   | `~/.claude-mem/chroma-sync-state.json` — real per-project counts of stored observations + summaries, × `MEM_EST_TOKENS_PER_ITEM` (est.) |
| caveman      | none — a SessionStart style nudge with no buffer transform, so no measurable byte delta → honest `N/A` |

For `context-mode`: invoke the `ctx_stats` MCP tool and parse the `total_size_kb` field, multiply by `1024 / TOKEN_CHARS_PER_TOKEN` (~4) to estimate tokens kept out of the context window.

**Monthly $ value.** After the per-tool table, `gain.sh` renders a per-month financial breakdown driven by `rtk gain --monthly` (RTK's `history.db` is the only timestamped source — claude-mem/caveman `gain.jsonl` has no history, context-mode reports a single total). Each month's saved tokens are valued at two providers' **input** list prices (savings are input-side context offload, so output price is not applied):

- `CLAUDE_INPUT_USD_PER_MTOK` — Claude Opus 4.8, `$5.00`/M (per the `claude-api` skill).
- `CODEX_INPUT_USD_PER_MTOK` — OpenAI Codex placeholder, `$1.25`/M — **verify and edit in `gain.sh`** against openai.com/pricing.

The `$` figure is the API-equivalent value of the savings (what those tokens would have cost at list price), not a subscription invoice. If `rtk` is absent or has no monthly rows, the section is omitted.

**Output format** (render in the response, do not write to a file):

```
# /tokenwar gain — token savings

  tool            saved       note
  ─────────────────────────────────────────────────────────────
  RTK             42.8M       16635 commands (72.0%)
  context-mode    X.XM        N entries indexed
  claude-mem      N/A         gain hook not installed
  caveman         N/A         gain hook not installed
  ─────────────────────────────────────────────────────────────
  TOTAL           42.8M       summed across tools with telemetry

Monthly value — API-equivalent $ saved (RTK)
  saved tokens × input list price · Claude Opus 4.8 $5.00/M · Codex (gpt-5-codex) $1.25/M
  month      saved       claude $      codex $
  ─────────────────────────────────────────────────────────────
  2026-03    18.4M       $92.00        $23.00
  2026-04    23.9M       $119.50       $29.88
  ─────────────────────────────────────────────────────────────
  TOTAL      42.8M       $214.36       $53.59
```

If the complementary check is `FAIL`, prefix the TOTAL line with `⚠️` and add `effective gain may be lower than reported — see /tokenwar check`. The user MUST not be told they're winning when two tools are double-processing the same buffer.

Each tool is read from its OWN native telemetry — never fabricate. If a source is missing (no `~/.claude-mem/chroma-sync-state.json`, no `CTX_STATS_JSON`, no `rtk`), that tool shows `N/A`, never `0`. caveman is always `N/A` by design — it has no telemetry surface.

## Subcommand: check

Run `bash ~/.claude/skills/tokenwar/scripts/check.sh`. The script encodes the following conflict rules:

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
# /tokenwar check

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

Stop at the first `FAIL` if the user typed `/tokenwar doctor --strict`; otherwise run all four sections regardless.

---

## Telemetry sources (per tool)

Each tool is read from its own native telemetry — `gain.sh` never fabricates:

- **RTK** — `rtk gain` / `rtk gain --monthly` (from its `history.db`).
- **context-mode** — the `ctx_stats` MCP tool (caller injects `CTX_STATS_JSON`).
- **claude-mem** — `~/.claude-mem/chroma-sync-state.json` (real stored-memory counts).
- **caveman** — none. It's a SessionStart prompt-style nudge with no buffer transform, so there is no before/after byte delta to measure. It is always `N/A` — do not wire a byte-logging hook for it; that would only fabricate numbers.

---

## Self-check before reporting back

After any subcommand:

1. Did every CLI call return exit code 0? If not, surface the failure — do not silently swallow.
2. Did you actually call `ctx_stats` (MCP tool), or did you skip context-mode because shell scripts can't reach it? Calling it is mandatory whenever the subcommand needs context-mode numbers.
3. Are the numbers you printed derived from real telemetry, or fabricated? If a tool's native source is missing, say `N/A`, not `0`.
4. Did you propose any auto-fix without asking via `AskUserQuestion`? That's a bug — every fix path goes through confirmation.
