# tokenwar

[![CI](https://github.com/oratelecom/tokenwar/actions/workflows/ci.yml/badge.svg)](https://github.com/oratelecom/tokenwar/actions/workflows/ci.yml)

**Five token-saving tools, run as one stack.** Built for Claude Code first — but the stack reaches further: RTK, ponytail, caveman and context-mode work across agents (Codex, Gemini, Cursor…), and Codex/Gemini token usage is tracked from native telemetry. Each compresses a buffer the others can't touch — the model's response, tool stdout, heavy data, cross-session memory, and the code itself — so the savings stack instead of competing. None of the five is the headliner; the genius is running all five at once. **5-in-1.**

Stack diagram: <https://studio.oratelecom.net/tokenwar/>

## The five tools

| Tool             | What it compresses                  | Buffer / flow                     |
| ---------------- | ----------------------------------- | --------------------------------- |
| **caveman**      | The LLM's response                  | `LLM → USER`                      |
| **RTK**          | Shell / tool stdout                 | `SHELL → LLM`                     |
| **context-mode** | Heavy data (HTTP, large files, MCP) | `LLM → SANDBOX → (FTS5) → LLM`    |
| **claude-mem**   | Cross-session knowledge             | `LLM → store → LLM (next session)`|
| **ponytail**     | The code the LLM writes             | `LLM → CODE (recurs on read)`     |

## Complementarity diagram

```mermaid
flowchart LR
    USER([👤 User])
    LLM{{🧠 LLM}}
    SHELL[/💻 Shell · tools/]
    SANDBOX[(🧪 Sandbox + FTS5)]
    MEM[(💾 claude-mem store)]
    CODE[/📄 Source on disk/]

    USER -->|prompt| LLM
    LLM -->|caveman ⤵ output compress| USER
    LLM -->|tool calls| SHELL
    SHELL -->|RTK ⤵ stdout compress| LLM
    LLM -->|context-mode ⤵ offload heavy ops| SANDBOX
    SANDBOX -->|FTS5 search results| LLM
    LLM -.->|persist session| MEM
    MEM -.->|recall on resume| LLM
    LLM ==>|ponytail ⤵ generate less code| CODE
    CODE -.->|RECURS · every future read · review · diff · grep| LLM

    classDef caveman fill:#fde68a,stroke:#b45309,color:#000;
    classDef rtk fill:#bae6fd,stroke:#0369a1,color:#000;
    classDef ctx fill:#bbf7d0,stroke:#15803d,color:#000;
    classDef mem fill:#e9d5ff,stroke:#7e22ce,color:#000;
    classDef pony fill:#fbcfe8,stroke:#be185d,color:#000;
    class USER caveman
    class SHELL rtk
    class SANDBOX ctx
    class MEM mem
    class CODE pony
```

Each tool acts on a **distinct buffer** — no buffer is double-processed, so the gains stack additively. Four lanes save on the live conversation (once per call); ponytail's lane saves on the artifact on disk (replayed on every future read via the dotted `CODE -.-> LLM` loop). Different shapes of saving, same stack.

## Why we picked each one — and why all five

No tool here is the headliner. Each was chosen because it owns a buffer the others physically can't reach, and on its own lane each is a killer. The genius isn't any single one — it's that the five run together with zero overlap, so every saving stacks. **Five tools, one stack, 5-in-1.**

### RTK — the shell/tool firehose
Tool output is the heaviest, most frequent buffer in an agent loop: every `git diff`, `ls`, test run, and API dump lands in context raw. RTK rewrites those commands at the hook level so only a compressed form reaches the model — transparently, zero prompt overhead, written in Rust so it's instant. It's the single biggest *measured* saver in the stack. **Picked because the firehose is where the tokens actually are.**

### context-mode — the heavy-data sandbox
One large file read or HTTP fetch can blow the whole window in a single call. context-mode runs the operation in a sandbox and indexes the result in FTS5, so you keep the derived answer (~3 KB) while the raw bytes (~700 KB) never enter the conversation — *think in code, not in raw output*. **Picked because some payloads should be processed, never read.**

### claude-mem — memory across sessions
Re-explaining the project every time you `/clear` or restart is pure repeated cost. claude-mem persists decisions, errors, and context to a store that survives compaction and is recalled next session — no re-priming. **Picked because the most expensive tokens are the ones you'd otherwise pay twice.**

### caveman — the response on a diet
The model's own prose is tokens too. caveman strips articles, filler, and hedging from what the LLM says while keeping the technical substance exact — terse output, same information. **Picked because a 5-line answer beats three paragraphs, every single turn.** (It's the prose twin of ponytail's code.)

### ponytail — the code itself
The lazy-senior-dev ruleset ([DietrichGebert/ponytail](https://github.com/DietrichGebert/ponytail)): a YAGNI ladder — stdlib before custom, native before dependency, one line before fifty, deletion before addition — so the model writes the *smallest correct* code, not an over-engineered one. Its saving lands twice: fewer **output** tokens at generation, then fewer **input** tokens on every future read/review/diff of a smaller file. **Picked because the cheapest code to maintain is the code that was never written.**

> Four save on the conversation, one saves on the artifact. One's a Rust hook, one's an MCP sandbox, one's a memory store, one's a response filter, one's a ruleset. Different shapes, different lanes — that's exactly why they stack. Run one and you compress one buffer; run all five and nothing in the loop is left uncompressed. **That's the 5-in-1.**

> Honest accounting: RTK / context-mode / claude-mem report real telemetry; caveman and ponytail are presence-only (a style nudge and a plugin ruleset — no metered buffer), so they show `on`, never a fabricated number. Measure ponytail by A/B-ing `/ponytail` on vs off — the [`examples/`](https://github.com/DietrichGebert/ponytail/tree/main/examples) show before/after diffs.

## Why complementary (not conflicting)

The tokenwar `check.sh` script enforces 4 rules:

| Rule | What it verifies                                                                   | Status                  |
| ---- | ---------------------------------------------------------------------------------- | ----------------------- |
| R1   | Single `PreToolUse` Bash hook in `settings.json` (RTK only — no double-rewrite)    | settings.json inspected |
| R2   | `claude-mem` writes to `~/.claude-mem`, `context-mode` to `~/.claude/projects/...` | Disjoint storage sinks  |
| R3   | RTK targets tool stdout; caveman targets LLM output                                | Disjoint buffers        |
| R4   | All 4 installed at current versions                                                | `claude plugin list`    |

When all four PASS, the verdict is `COMPLEMENTARY`. ponytail isn't in the table because it owns no hook, store, or output buffer — it only shapes what the model writes, so it can't collide with any of the four. Five tools, still zero overlap.

## Commands

Inside Claude Code (`/tokenwar <subcommand>`) or standalone (`bash ~/.claude/skills/tokenwar/scripts/<script>.sh`):

| Command | What it does |
| --- | --- |
| `/tokenwar status` | Health of the 4 tools — installed, enabled, version |
| `/tokenwar gain` | Per-tool token savings + per-provider (Codex/Gemini native telemetry) + **monthly $ value** |
| `/tokenwar upgrade` | Bump each tool to latest (asks confirmation) |
| `/tokenwar check` | Conflict detector — verifies the 4 stack additively |
| `/tokenwar test` | End-to-end ping: is each tool actually working? |
| `/tokenwar doctor` | Full pipeline: status → test → check → gain |

## Status in every CLI (Claude, Codex, Gemini)

The persistent **bottom status bar** is a Claude Code feature — it ships a
`statusLine` API and tokenwar wires it automatically. **Codex and Gemini do not
expose a status-bar API** (their footers are hardcoded; their hooks inject only
into the model context, not the screen). So tokenwar surfaces the stack the best
way each CLI allows, with **zero daily effort** — `install.sh` wires it once:

| CLI         | What you get                                                          |
| ----------- | --------------------------------------------------------------------- |
| Claude Code | Native persistent bottom bar (always visible)                         |
| Codex       | Launch banner + `tokenwar status` reminder + inline upgrade prompt    |
| Gemini CLI  | Launch banner + `tokenwar status` reminder + inline upgrade prompt    |

After install you simply type `codex` or `gemini` as usual — the banner prints,
and if updates are pending you get **"⬆ N updates available. Upgrade now? [y/N]"**
which bumps the 4 tools. A `tokenwar` command also works in any shell:

```bash
tokenwar status     # state of the 4 tools + providers
tokenwar gain       # token savings + monthly $ value
tokenwar upgrade    # bump the 4 tools (asks confirmation)
tokenwar doctor     # status → check → gain
```

> The banner is silent for non-interactive launches (`codex exec`,
> `gemini -p …`, pipes) so it never pollutes scripted output.

## Quick start

One-liner install (clone + chmod + wire statusline):

```bash
curl -fsSL https://raw.githubusercontent.com/oratelecom/tokenwar/main/install.sh | bash
```

Then activate the four tools from inside Claude Code:

```
/tokenwar activate
```

Uninstall:

```bash
curl -fsSL https://raw.githubusercontent.com/oratelecom/tokenwar/main/uninstall.sh | bash
```

### Manual install

```bash
git clone https://github.com/oratelecom/tokenwar ~/.claude/skills/tokenwar
chmod +x ~/.claude/skills/tokenwar/scripts/*.sh

# Diagnose current state
bash ~/.claude/skills/tokenwar/scripts/status.sh

# Verify complementarity
bash ~/.claude/skills/tokenwar/scripts/check.sh

# Token savings report (per-tool + monthly $ value)
bash ~/.claude/skills/tokenwar/scripts/gain.sh
```

`gain.sh` reads each tool from its **own native telemetry** — never fabricated:
RTK (`rtk gain`), context-mode (`ctx_stats`), claude-mem
(`~/.claude-mem/chroma-sync-state.json` stored-memory counts). caveman is a
style-only nudge with no measurable buffer, so it is always `N/A`. It also
prints a per-month breakdown from `rtk gain --monthly`, valuing each month's
saved tokens at Claude and Codex input list prices (the API-equivalent $ saved).

Wire the combined statusline (Claude Code, `~/.claude/settings.json`):

```json
"statusLine": {
  "type": "command",
  "command": "bash ~/.claude/skills/tokenwar/scripts/tokenwar-statusline.sh"
}
```

Statusline renders `[ctx <v>] [mem <v>] [rtk <saved>] [caveman <v>] [ponytail on]` — green if active, red if down. The `ponytail` badge reflects the plugin's real runtime mode: green with the active intensity (`on` for full, else `lite`/`ultra`) when the `ponytail@ponytail` plugin is enabled and not toggled off, red `off` when disabled or after `/ponytail off` — read live from the plugin's `~/.claude/.ponytail-active` flag, no version, no telemetry, by design. A yellow `⬆` is appended to any tool with an available update (from the throttled `check-updates.sh` cache, refreshed in the background), and when ≥1 update exists the bar ends with a `⬆ N updates · /tokenwar upgrade` call-to-action. The bar is **Claude-only** — Codex/Gemini are tracked in `/tokenwar gain`, not on the Claude status bar.

## Settings.json wipe protection

Claude Code can rewrite `~/.claude/settings.json` on session start (migration logic). A backup is kept at `~/.claude/settings.local.json` and a restore script merges it back:

```bash
bash ~/.claude/skills/tokenwar/scripts/restore-settings.sh
```

Add to `~/.bashrc` to auto-restore before each Claude Code launch:

```bash
alias claude='bash ~/.claude/skills/tokenwar/scripts/restore-settings.sh && command claude'
```

## Tests + CI

```bash
bats tests/
```

CI on every push to `main` and every PR — installs bats + shellcheck, runs full suite on `ubuntu-latest`.

## Credits

**Powered by [Ora Studio](https://studio.oratelecom.net) · Ora Telecom** — token economics, productized.

Our open-source footprint on the 4-tool stack:

| Status | Project | Role |
| :----: | ------- | ---- |
| ✓ | **RTK**          | upstream contributor |
| ✓ | **context-mode** | upstream contributor |
| ✓ | **claude-mem**   | upstream contributor |
| ✦ | **caveman**      | Ora maintenance landing soon |

## License

[MIT](LICENSE) — © 2026 Ora Telecom. Use, fork, ship — no strings.
