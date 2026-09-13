# Commands and operations

## Commands

Inside Claude Code (`/tokenwar <subcommand>`) or standalone (`bash ~/.claude/skills/tokenwar/scripts/<script>.sh`):

| Command | What it does |
| --- | --- |
| `/tokenwar status` | Health of the 7 tools — installed, enabled, version |
| `/tokenwar gain` | Per-tool token savings + per-provider telemetry/status (Codex/Gemini/Kimi/opencode) + **monthly $ value** |
| `/tokenwar scan` | Local agent-log audit: what loads into every request vs what you actually use, with cache-adjusted cost |
| `/tokenwar prune` | List skills and MCP servers that load every request but were never invoked |
| `/tokenwar bundle <mode>` | Apply a session-start tool bundle (`dev`/`devops`/`architect`/`testing`) |
| `/tokenwar copilot` | Report which tools reach GitHub Copilot CLI; `copilot wire` points the missing ones at Copilot's hook / skills / MCP |
| `/tokenwar upgrade` | Bump each tool to latest (asks confirmation) |
| `/tokenwar check` | Conflict detector — verifies the 7 tools stack additively |
| `/tokenwar test` | End-to-end ping: is each tool actually working? |
| `/tokenwar doctor` | Full pipeline: status → test → check → gain |
| `/tokenwar disable <tool>` | Turn off one plugin (`context-mode`/`claude-mem`/`caveman`/`ponytail`) without uninstalling it. `rtk`, `pxpipe`, and `graphify` are binaries, not plugins — the command prints their own on/off mechanism instead |
| `/tokenwar enable <tool>` | Turn a disabled plugin back on |

## Status in every CLI (Claude, Codex, Gemini, Kimi, opencode, Copilot)

The persistent **bottom status bar** is a Claude Code feature — it ships a
`statusLine` API and tokenwar wires it automatically. **Codex, Gemini, Kimi,
opencode, and GitHub Copilot CLI do not expose a status-bar API** (their footers
are hardcoded; their hooks inject only into the model context, not the screen).
So tokenwar surfaces the stack the best way each CLI allows, with **zero daily
effort** — `install.sh` wires it once:

| CLI         | What you get                                                          |
| ----------- | --------------------------------------------------------------------- |
| Claude Code | Native persistent bottom bar (always visible)                         |
| Codex       | Launch banner + `tokenwar status` reminder + update status hint       |
| Gemini CLI  | Launch banner + `tokenwar status` reminder + update status hint       |
| Kimi Code CLI | Launch banner + `tokenwar status` reminder + update status hint     |
| opencode    | Launch banner + `tokenwar status` reminder + update status hint       |
| GitHub Copilot CLI | Launch banner + `tokenwar status` reminder + update status hint |

After install you simply type `codex`, `gemini`, `kimi`, `opencode`, or `copilot` as usual —
the banner prints the stack bar. If updates are pending, the bar shows
**"⬆ N updates · /tokenwar upgrade"** as an informational hint only; upgrades
run only when you call `tokenwar upgrade` yourself. A `tokenwar` command also
works in any shell:

```bash
tokenwar status     # state of the 7 tools + providers
tokenwar gain       # token savings + monthly $ value
tokenwar scan       # local log scan + recommendations
tokenwar copilot    # which tools reach GitHub Copilot CLI (add `wire` to fix)
tokenwar upgrade    # bump managed tools (asks confirmation)
tokenwar doctor     # status → check → gain
tokenwar disable context-mode   # turn off one plugin without uninstalling it
tokenwar enable  context-mode   # turn it back on
```

> The banner is silent for non-interactive launches (`codex exec`,
> `gemini -p …`, `kimi -p …`, `opencode run …`, `copilot -p …`, `copilot --acp`,
> `copilot mcp/skill/plugin …`, pipes) so it never pollutes scripted output.

## Settings.json wipe protection

Claude Code can rewrite `~/.claude/settings.json` on session start (migration logic). A backup is kept at `~/.claude/settings.local.json` and a restore script merges it back:

```bash
bash ~/.claude/skills/tokenwar/scripts/restore-settings.sh
```

Add to `~/.bashrc` to auto-restore before each Claude Code launch:

```bash
alias claude='bash ~/.claude/skills/tokenwar/scripts/restore-settings.sh && command claude'
```

## Plugin-state detection (robust on any host)

`tokenwar status` reads the 4 Claude Code plugins' state from `claude plugin list --json` — the authoritative source (installed **and** enabled state in one shot). On hosts where that command returns nothing (an older `claude` CLI without the subcommand, or `claude` not on `PATH` in the shell running tokenwar), status falls back to on-disk config instead of reporting every plugin as *not installed*:

- `~/.claude/plugins/installed_plugins.json` → what is installed,
- `enabledPlugins` OR-merged from `settings.json` **and** `settings.local.json` → the enabled/disabled bit (Claude Code merges both at runtime).

An installed plugin absent from `enabledPlugins` is treated as enabled (Claude default); an explicit `false` stays `installed-disabled` — so `tokenwar disable <tool>` is always reflected correctly. Override the config dir with `CLAUDE_CONFIG_DIR`.

## Tests + CI

```bash
bats tests/
```

CI on every push to `main` and every PR — installs bats + shellcheck, runs the
full suite on `ubuntu-latest`, then a contract smoke that asserts every managed
tool **and every provider** is present in `status.sh --json` and `gain.sh --json`.
The smoke is what catches a tool or provider added to the text table but
forgotten in the JSON contract that `tokenwar scan` and downstream consumers
read — the two are rendered by separate code paths.
