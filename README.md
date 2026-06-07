# tokenwar

[![CI](https://github.com/oratelecom/tokenwar/actions/workflows/ci.yml/badge.svg)](https://github.com/oratelecom/tokenwar/actions/workflows/ci.yml)

**A 4-tool token-saving stack for Claude Code.** Each tool compresses a different buffer — they stack without overlap.

Stack diagram: <https://studio.oratelecom.net/tokenwar/>

## The 4 tools

| Tool             | What it compresses                  | Buffer / flow                     |
| ---------------- | ----------------------------------- | --------------------------------- |
| **caveman**      | The LLM's response                  | `LLM → USER`                      |
| **RTK**          | Shell / tool stdout                 | `SHELL → LLM`                     |
| **context-mode** | Heavy data (HTTP, large files, MCP) | `LLM → SANDBOX → (FTS5) → LLM`    |
| **claude-mem**   | Cross-session knowledge             | `LLM → store → LLM (next session)`|

## Complementarity diagram

```mermaid
flowchart LR
    USER([👤 User])
    LLM{{🧠 LLM}}
    SHELL[/💻 Shell · tools/]
    SANDBOX[(🧪 Sandbox + FTS5)]
    MEM[(💾 claude-mem store)]

    USER -->|prompt| LLM
    LLM -->|caveman ⤵ output compress| USER
    LLM -->|tool calls| SHELL
    SHELL -->|RTK ⤵ stdout compress| LLM
    LLM -->|context-mode ⤵ offload heavy ops| SANDBOX
    SANDBOX -->|FTS5 search results| LLM
    LLM -.->|persist session| MEM
    MEM -.->|recall on resume| LLM

    classDef caveman fill:#fde68a,stroke:#b45309,color:#000;
    classDef rtk fill:#bae6fd,stroke:#0369a1,color:#000;
    classDef ctx fill:#bbf7d0,stroke:#15803d,color:#000;
    classDef mem fill:#e9d5ff,stroke:#7e22ce,color:#000;
    class USER caveman
    class SHELL rtk
    class SANDBOX ctx
    class MEM mem
```

Each tool acts on a **distinct buffer**. No buffer is double-processed, so the gains stack additively.

## Why complementary (not conflicting)

The tokenwar `check.sh` script enforces 4 rules:

| Rule | What it verifies                                                                   | Status                  |
| ---- | ---------------------------------------------------------------------------------- | ----------------------- |
| R1   | Single `PreToolUse` Bash hook in `settings.json` (RTK only — no double-rewrite)    | settings.json inspected |
| R2   | `claude-mem` writes to `~/.claude-mem`, `context-mode` to `~/.claude/projects/...` | Disjoint storage sinks  |
| R3   | RTK targets tool stdout; caveman targets LLM output                                | Disjoint buffers        |
| R4   | All 4 installed at current versions                                                | `claude plugin list`    |

When all four PASS, the verdict is `COMPLEMENTARY`.

## Commands

Inside Claude Code (`/tokenwar <subcommand>`) or standalone (`bash ~/.claude/skills/tokenwar/scripts/<script>.sh`):

| Command | What it does |
| --- | --- |
| `/tokenwar status` | Health of the 4 tools — installed, enabled, version |
| `/tokenwar gain` | Per-tool token savings + **monthly $ value** (Claude/Codex) |
| `/tokenwar upgrade` | Bump each tool to latest (asks confirmation) |
| `/tokenwar check` | Conflict detector — verifies the 4 stack additively |
| `/tokenwar test` | End-to-end ping: is each tool actually working? |
| `/tokenwar doctor` | Full pipeline: status → test → check → gain |

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

Statusline renders `[ctx <v>] [mem <v>] [rtk <saved>] [caveman <v>]` — green if active, red if down. A yellow `⬆` is appended to any tool with an available update (from the throttled `check-updates.sh` cache, refreshed in the background), and when ≥1 update exists the bar ends with a `⬆ N updates · /tokenwar upgrade` call-to-action.

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

**Powered by [Ora Studio](https://studio.oratelecom.net) · [Ora Telecom](https://oratelecom.com)** — token economics, productized.

Our open-source footprint on the 4-tool stack:

| Status | Project | Role |
| :----: | ------- | ---- |
| ✓ | **RTK**          | upstream contributor |
| ✓ | **context-mode** | upstream contributor |
| ✓ | **claude-mem**   | upstream contributor |
| ✦ | **caveman**      | Ora maintenance landing soon |

## License

[MIT](LICENSE) — © 2026 Ora Telecom. Use, fork, ship — no strings.
