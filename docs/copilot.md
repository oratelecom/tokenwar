# GitHub Copilot CLI integration

## The stack inside GitHub Copilot CLI

Being a tracked *provider* only gets you the numbers. The **tools** are published
for Claude Code and do not reach Copilot for free — each one has to be pointed at
Copilot's own extension points, of which there are exactly three: hooks
(`~/.copilot/hooks/*.json`), skills (`~/.copilot/skills/<name>/SKILL.md`, the
portable Agent-Skills format), and MCP (`~/.copilot/mcp-config.json`).

`tokenwar copilot` reports that mapping; `tokenwar copilot wire` applies it.

| Tool | Reaches Copilot via | Wiring |
| ---- | ------------------- | ------ |
| **rtk** | hook | `rtk init -g --copilot` — a `PreToolUse` hook plus user-level instructions |
| **graphify** | skill | `graphify copilot install` — its own native command |
| **caveman** | skill | `copilot skill add` on the plugin's `SKILL.md` |
| **ponytail** | skill | `copilot skill add` on the plugin's `SKILL.md` |
| **claude-mem** | MCP | its own `.mcp.json` definition, re-registered with `copilot mcp add` |
| context-mode | — | not wired: its plugin manifest pins an absolute, version-specific interpreter path, so the registration would break on the next upgrade |
| pxpipe | — | not applicable: it is a proxy on the Anthropic-compatible API path, and Copilot talks to GitHub's endpoint |

```text
# /tokenwar copilot

  ·  tool          via       state             note
  ─────────────────────────────────────────────────────────────────
  ✓  rtk           hook      wired             ~/.copilot/hooks/rtk-rewrite.json
  ✓  graphify      skill     wired             ~/.copilot/skills/graphify
  ✓  caveman       skill     wired             ~/.copilot/skills/caveman
  ✓  ponytail      skill     wired             ~/.copilot/skills/ponytail
  ✓  claude-mem    MCP       wired             ~/.copilot/mcp-config.json → claude-mem
```

Two details that are easy to get wrong:

- **claude-mem is registered from its own `.mcp.json`, not from a hardcoded
  path.** That file wraps a locator which resolves the current plugin version at
  runtime, so the Copilot registration survives `claude plugin update`. Pointing
  Copilot straight at `.../claude-mem/13.6.1/scripts/mcp-server.cjs` works right
  up until the next upgrade.
- **claude-mem's first search needs a longer timeout than either default
  allows.** Its MCP server talks to a local worker over HTTP and aborts at
  `CLAUDE_MEM_API_TIMEOUT_MS` (30s by default); the first search after a cold
  worker path builds an index over the whole memory DB — measured at **2m02s**
  here. With the defaults the very first call in a Copilot session *always*
  fails, which reads as "claude-mem is broken under Copilot" when it is not. The
  wiring therefore raises both that variable and Copilot's own per-tool timeout.

`install.sh --with-copilot` (included in `--all`) runs the same wiring at install
time — it delegates to `scripts/copilot.sh`, so there is one implementation, not
two that drift.

## How to activate tokenwar per client

Run the installer **once** — it wires every client it can find. There is no
per-client install step; the difference is only *how the stack shows up* in each.

```bash
curl -fsSL https://raw.githubusercontent.com/oratelecom/tokenwar/main/install.sh | bash -s -- --all
```

| Client        | What `install.sh` does for it                                         | How you confirm it's active |
| ------------- | --------------------------------------------------------------------- | --------------------------- |
| **Claude Code** | Installs the 4 plugins + RTK hook + pxpipe, patches `statusLine` in `~/.claude/settings.json` | Restart Claude Code → persistent bottom bar `[ctx][mem][rtk][caveman][ponytail]` |
| **Codex**     | Wraps `codex` with a shell function that prints the tokenwar banner on launch | Open a new shell, run `codex` → banner appears; `tokenwar status` works |
| **Gemini CLI** | Wraps `gemini` the same way                                          | New shell, run `gemini` → banner |
| **Kimi Code CLI** | Wraps `kimi` the same way                                         | New shell, run `kimi` → banner |
| **opencode**  | Wraps `opencode` the same way; reads its real token telemetry from `~/.local/share/opencode/opencode.db` | New shell, run `opencode` → banner; `tokenwar gain` shows opencode session tokens |
| **GitHub Copilot CLI** | Wraps `copilot` the same way; reads its real token + AI-credit telemetry from `~/.copilot/session-store.db`; with `--with-copilot`, also points the tools at Copilot's own hook / skills / MCP | New shell, run `copilot` → banner; `tokenwar copilot` shows every tool `wired` |

After install, **reload your shell** (`source ~/.bashrc` or open a new terminal)
so the `codex` / `gemini` / `kimi` / `opencode` / `copilot` / `tokenwar` functions
take effect.
That's the whole activation — every subsequent launch of any wrapped CLI is
tokenwar-aware with zero extra effort.

Only want one client? The wrappers are wired for all of them regardless, but you
never pay for a client you don't use: an absent CLI is simply never invoked, and
`tokenwar status` reports it as *not installed* without failing.
