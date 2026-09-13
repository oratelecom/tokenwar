# Savings and stack design

## The seven tools

| Tool             | What it compresses                  | Buffer / flow                     |
| ---------------- | ----------------------------------- | --------------------------------- |
| **caveman**      | The LLM's response                  | `LLM → USER`                      |
| **RTK**          | Shell / tool stdout                 | `SHELL → LLM`                     |
| **context-mode** | Heavy data (HTTP, large files, MCP) | `LLM → SANDBOX → (FTS5) → LLM`    |
| **claude-mem**   | Cross-session knowledge             | `LLM → store → LLM (next session)`|
| **pxpipe**       | Provider-bound prompt/context payloads | `LLM → proxy → PNG blocks → API` |
| **graphify**     | Repo/doc discovery sweeps           | `REPO → graph → query → LLM`      |
| **ponytail**     | The code the LLM writes             | `LLM → CODE (recurs on read)`     |

Each tool acts on a **distinct buffer or lane** — no buffer is double-processed,
so the gains stack additively. Six lanes save on the live conversation or
provider request path; ponytail's lane saves on the artifact on disk and recurs
on every future read, review, diff, and grep. Different shapes of saving, same
stack.

## Why we picked each one — and why all seven

No tool here is the headliner. Each was chosen because it owns a buffer the others physically can't reach, and on its own lane each is a killer. The point isn't any single one — it's that the seven run together with zero overlap, so every saving stacks. **Seven tools, one stack, 7-in-1.**

### RTK — the shell/tool firehose
Tool output is the heaviest, most frequent buffer in an agent loop: every `git diff`, `ls`, test run, and API dump lands in context raw. RTK rewrites those commands at the hook level so only a compressed form reaches the model — transparently, zero prompt overhead, written in Rust so it's instant. It's the single biggest *measured* saver in the stack. **Picked because the firehose is where the tokens actually are.**

### context-mode — the heavy-data sandbox
One large file read or HTTP fetch can blow the whole window in a single call. context-mode runs the operation in a sandbox and indexes the result in FTS5, so you keep the derived answer (~3 KB) while the raw bytes (~700 KB) never enter the conversation — *think in code, not in raw output*. **Picked because some payloads should be processed, never read.**

### claude-mem — memory across sessions
Re-explaining the project every time you `/clear` or restart is pure repeated cost. claude-mem persists decisions, errors, and context to a store that survives compaction and is recalled next session — no re-priming. **Picked because the most expensive tokens are the ones you'd otherwise pay twice.**

### pxpipe — the provider-bound prompt payload
[teamchong/pxpipe](https://github.com/teamchong/pxpipe) is a local API proxy that converts selected prompt/context text into PNG blocks before forwarding the request to the provider. That attacks a different lane from RTK: RTK compresses shell output before it enters model context; pxpipe compresses expensive prompt payloads at the provider boundary and records savings in `~/.pxpipe/events.jsonl`. **Picked because some repeated or bulky text is cheaper as pixels than as input tokens.**

### graphify — the repo's shape, asked instead of grepped
[Graphify-Labs/graphify](https://github.com/Graphify-Labs/graphify) parses a repo — code, docs, SQL schemas, configs, PDFs — into a local knowledge graph with deterministic AST parsing and every edge explained. The lane it owns is *discovery*: "where is this wired", "what breaks if I change X", "how does the api reach the data layer". Without it an agent answers those with a burst of `rg`/`find`/`sed`/`cat` sweeps whose combined output is the single largest avoidable read in most logs — and RTK can only compress what those commands already printed, it cannot stop them being run. graphify replaces the sweep with one bounded `graphify query`. Its own `graphify benchmark` measures the delta on your graph (a 236-node graph here: ~15.7K tokens to read the corpus naively vs ~347 per graph query). **Picked because the cheapest discovery output is the one that was never printed.**

### caveman — the response on a diet
The model's own prose is tokens too. caveman strips articles, filler, and hedging from what the LLM says while keeping the technical substance exact — terse output, same information. **Picked because a 5-line answer beats three paragraphs, every single turn.** (It's the prose twin of ponytail's code.)

### ponytail — the code itself
The lazy-senior-dev ruleset ([DietrichGebert/ponytail](https://github.com/DietrichGebert/ponytail)): a YAGNI ladder — stdlib before custom, native before dependency, one line before fifty, deletion before addition — so the model writes the *smallest correct* code, not an over-engineered one. Its saving lands twice: fewer **output** tokens at generation, then fewer **input** tokens on every future read/review/diff of a smaller file. **Picked because the cheapest code to maintain is the code that was never written.**

> Six save on the conversation/provider path, one saves on the artifact. One's a Rust hook, one's an MCP sandbox, one's a memory store, one's a proxy, one's a graph, one's a response filter, one's a ruleset. Different shapes, different lanes — that's exactly why they stack. Run one and you compress one buffer; run all seven and almost nothing in the loop is left uncompressed. **That's the 7-in-1.**

> Honest accounting: RTK / context-mode / claude-mem / pxpipe report real telemetry; caveman and ponytail are presence-only (a style nudge and a plugin ruleset — no metered buffer), so they show `on`, never a fabricated number. graphify reports a *per-query* reduction ratio measured by its own `graphify benchmark`, which is not a cumulative saved-token counter — so tokenwar prints the ratio in the note and leaves the token column `N/A` rather than summing a per-query figure into the TOTAL. pxpipe savings come only from its native `~/.pxpipe/events.jsonl`; if no events exist, tokenwar prints `N/A`. Measure ponytail by A/B-ing `/ponytail` on vs off — the [`examples/`](https://github.com/DietrichGebert/ponytail/tree/main/examples) show before/after diffs.

## Why complementary (not conflicting)

The tokenwar `check.sh` script enforces 5 rules:

| Rule | What it verifies                                                                   | Status                  |
| ---- | ---------------------------------------------------------------------------------- | ----------------------- |
| R1   | Single `PreToolUse` Bash hook in `settings.json` (RTK only — no double-rewrite)    | settings.json inspected |
| R2   | `claude-mem` writes to `~/.claude-mem`, `context-mode` to `~/.claude/projects/...` | Disjoint storage sinks  |
| R3   | RTK targets tool stdout; caveman targets LLM output                                | Disjoint buffers        |
| R4   | Core hook/plugin/CLI tools installed (incl. rtk, pxpipe, graphify)                 | `claude plugin list` + `command -v` |
| R5   | Active providers use separate config directories                                   | Disjoint provider state |

When all five PASS, the verdict is `COMPLEMENTARY`. ponytail shapes what the
model writes; pxpipe is tracked in `status`, `gain`, `updates`, and `upgrade`
and sits at the provider proxy boundary, separate from RTK's shell-output lane;
graphify sits one step earlier still, cutting the discovery commands before RTK
ever has stdout to compress. Seven tools, still zero overlap.

### What the savings look like (live run)

A real `tokenwar gain` on an active dev machine — every number comes from each
tool's own telemetry, nothing invented:

```text
# /tokenwar gain — token savings

  tool            saved       note
  ─────────────────────────────────────────────────────────────
  RTK             8.5M        13837 commands (68.6%)
  context-mode    N/A         ctx_stats not provided by caller
  claude-mem      4.9M        ~est: 98401 obs + 23338 summaries across 36 projects
  caveman         N/A         style-only hook — no measurable buffer
  pxpipe          N/A         pxpipe events log not found
  graphify        N/A         236 nodes in the global graph, 45.3x fewer tokens per query
  ─────────────────────────────────────────────────────────────
  TOTAL (tools)   13.4M       summed across tools with telemetry

  provider        tokens      note
  ─────────────────────────────────────────────────────────────
  Codex           3680.3M     320 Codex sessions (real tokens_used)
  Gemini CLI      N/A         no local token telemetry (server-side sessions)
  Kimi Code CLI   N/A         no documented local token telemetry
  opencode        105.3K      10 opencode sessions (real token cols)
  Copilot CLI     13.3K       1 Copilot sessions (real assistant_usage_events) - 0.24 AI credits billed

Monthly value — API-equivalent $ saved (Claude Opus 4.8 · input $5.00/M)
  2026-07    8.2M        $41.00
  TOTAL      8.4M        $42.16
```

That's **13.4M tokens saved** on Claude-side context alone (RTK compressing tool
stdout at 68.6%, claude-mem offloading cross-session memory), worth ~**$42/month**
in Opus 4.8 input-equivalent — and the provider rows show each wrapped CLI's real
usage read from its native store (**opencode from `opencode.db`, Codex from its
SQLite**), so you see per-agent token flow next to the savings. Run it yourself
with `tokenwar gain` after a few days of use.

Wire the combined statusline (Claude Code, `~/.claude/settings.json`):

```json
"statusLine": {
  "type": "command",
  "command": "bash ~/.claude/skills/tokenwar/scripts/tokenwar-statusline.sh"
}
```

Statusline renders `[ctx <v>] [mem <v>] [rtk <saved>] [caveman <v>] [ponytail on] [pxpipe <v>] [graphify <v>]` — green if active, red if down. The `ponytail` badge reflects the plugin's real runtime mode: green with the active intensity (`on` for full, else `lite`/`ultra`) when the `ponytail@ponytail` plugin is enabled and not toggled off, red `off` when disabled or after `/ponytail off` — read live from the plugin's `~/.claude/.ponytail-active` flag, no version, no telemetry, by design. A yellow `⬆` is appended to any tool with an available update (from the throttled `check-updates.sh` cache, refreshed in the background), and when ≥1 update exists the bar ends with a `⬆ N updates · /tokenwar upgrade` call-to-action. The bar is **Claude-only** — Codex/Gemini/Kimi/opencode are tracked in `/tokenwar gain`, not on the Claude status bar.
