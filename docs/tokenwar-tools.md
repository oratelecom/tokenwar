# TokenWar Tool Map

TokenWar should recommend tools by buffer, not by hype. A good scan asks:
which part of the agent loop burned tokens, which tool owns that lane, and
whether the host can install it safely.

## Core Stack

| Tool | Best At | Weakness | Use When | Avoid When | Telemetry |
| --- | --- | --- | --- | --- | --- |
| [RTK](https://github.com/rtk-ai/rtk) | Compressing shell/tool output before it enters agent context. | Only sees hooked shell commands; native file-read tools bypass it. | Logs show many `git`, `rg`, `find`, `sed`, `cat`, test, Docker, or `gh` calls. | The agent mostly uses non-shell structured tools or exact raw output is required by a parser. | Native `rtk gain` and monthly rows. |
| [pxpipe](https://github.com/teamchong/pxpipe) | Shrinking provider-bound prompt/context payloads by rendering bulky text as image blocks. | Provider/model dependent; exact identifiers in images need a companion factsheet. | Long repeated prompts, generated docs, large structured payloads, or proxy-compatible Claude traffic. | The provider has weak/expensive vision support or exact text fidelity is more important than payload size. | Native `~/.pxpipe/events.jsonl` / `pxpipe stats`. |
| [claude-mem](https://github.com/thedotmack/claude-mem) | Cross-session memory and compact recall. | Recall quality depends on write quality; can duplicate another memory layer if unmanaged. | Logs repeat project setup, rules, prior decisions, PR state, or "resume where we were" context. | One-shot work with no future session value. | Native state in `~/.claude-mem/chroma-sync-state.json`; token count is estimated per memory item. |
| [caveman](https://github.com/JuliusBrussee/caveman) | Cutting verbose assistant prose. | Style-only; no native before/after byte telemetry. | The agent writes long explanations, status updates, reviews, or commit summaries. | User-facing prose needs normal tone, legal/medical nuance, or detailed teaching. | Presence only; scan can estimate opportunity from transcript volume, not actual savings. |
| [ponytail](https://github.com/DietrichGebert/ponytail) | Smaller code and less abstraction. | Ruleset only; needs review discipline to avoid under-building. | Vibe coding, greenfield code, refactors, UI work, and repeated agent-authored diffs. | Protocol-heavy or compatibility-heavy code where explicit structure is required. | Presence only; savings compound through smaller future reads/diffs/reviews. |
| [context-mode](https://github.com/mksglu/context-mode) | Sandboxed heavy data processing and FTS-backed recall. | MCP startup/tool latency, broader moving parts, and license review risk before bundling. | Huge files, HTTP responses, PDFs, scraped pages, or data that should be queried instead of pasted. | Fast local code lookup is the main need; prefer a lighter repo-map/code-search tool. | `ctx_stats` MCP data, injected into `gain.sh` as `CTX_STATS_JSON`. |

## Knowledge And Navigation Tools

These do not replace the six core lanes. They reduce exploration loops, which
is often where agents quietly waste tokens before writing code.

| Tool | Best At | Weakness | TokenWar Position |
| --- | --- | --- | --- |
| [Graphify](https://github.com/Graphify-Labs/graphify) | Local knowledge graph over code, docs, SQL, configs, and PDFs; queryable structure across a project. | Graph build step and project artifacts must stay scoped to repos that actually use it. | Recommend when logs show repeated cross-file discovery, architecture questions, or `rg/find/sed` sweeps. |
| [OpenWiki](https://github.com/langchain-ai/openwiki) | Durable Markdown wiki maintained by an agent, good for onboarding and purpose memory. | It creates/maintains docs; it is not a live low-latency grep replacement. | Recommend when agents keep re-reading project rules, architecture, setup, and "why" context. |
| [Serena](https://github.com/oraios/serena) | MCP-backed IDE-like symbol retrieval, reference lookup, refactoring, and debugging. | MCP dependency and language-server quality vary by repo/language. | Strong candidate when exact symbol navigation would replace many file reads. |
| [Probe](https://github.com/probelabs/probe) | Code and Markdown context engine with AST parsing, semantic search, CLI, MCP, and SDK modes. | Smaller ecosystem than Serena; benchmark locally before defaulting. | Preferred context-mode alternative for code search because it offers direct CLI usage, not only MCP. |
| [Stacklit](https://github.com/glincker/stacklit) | Compact repo map (`stacklit.json`) that agents can read instead of exploring. | Newer/smaller project; less semantic depth than IDE/LSP tools. | Good low-friction context-mode alternative for fast first-pass repo orientation. |
| [codebase-memory-mcp](https://github.com/DeusData/codebase-memory-mcp) | Native-binary knowledge graph with broad language coverage and very fast queries. | MCP tool, so still a process/tooling integration; verify claims and release trust before bundling. | Candidate for local-first structural memory when speed matters. |
| [Argyph](https://github.com/ezzy1630/Argyph) | Local binary combining grep, symbol graph, semantic search, and repo packing. | Young project with limited adoption. | Watchlist; promising shape but not a default recommendation yet. |
| [context-link](https://github.com/context-link-mcp/context-link) | Local MCP gateway using tree-sitter symbol/dependency context with token-savings metadata. | Young project; MCP-only surface. | Watchlist for users who want MCP but not context-mode. |
| [Claude Context](https://github.com/zilliztech/claude-context) | Semantic code search over large codebases. | Requires external vector database and embedding API keys by default. | Not a default TokenWar recommendation for local-only scans. |

## Recommendation Matrix

| Log Signal | Recommend | Reason |
| --- | --- | --- |
| Many shell calls or huge command outputs | RTK | It owns `SHELL -> LLM` stdout compression. |
| Repeated `rg/find/sed/cat/ls/git diff` exploration | Probe, Stacklit, Graphify, Serena | Replace multi-step discovery with maps, symbol lookup, or graph queries. |
| Huge HTTP/file/PDF/scrape payloads | Probe for code, context-mode or context-link for sandboxed heavy data | Do not paste raw payloads into the transcript. Query/index them locally. |
| Repeated project recap after session restarts | claude-mem and OpenWiki | Persist facts once, recall compactly later. |
| Long assistant prose or long review comments | caveman | It targets `LLM -> USER` output. |
| Lots of generated code, repeated refactors, large diffs | ponytail | Smaller code saves output now and input later. |
| Long provider-bound prompts/context with proxy-compatible traffic | pxpipe | It attacks the provider API payload lane, separate from shell output. |

## Current Context-Mode Stance

Do not make context-mode the default replacement for every code-navigation
case. It remains valuable for sandboxed heavy data and FTS-style offload, but
for local code navigation TokenWar should test lighter alternatives first:

1. Probe when a direct CLI/MCP code context engine is enough.
2. Stacklit when a compact repo map should replace first-pass exploration.
3. Serena when symbol-aware MCP/LSP navigation is worth the MCP overhead.
4. Graphify when project structure and cross-document relationships matter.
5. context-mode only when the workload is heavy data offload or sandboxed
   content processing rather than normal repo search.

## Scan Contract

`tokenwar scan` is an opportunity estimator. It must never present estimated
numbers as real savings.

- Actual savings: only from native telemetry (`rtk gain`, `pxpipe stats`,
  Codex/opencode token databases, `ctx_stats`).
- Estimated opportunity: derived from local logs by matching command, search,
  scrape, memory, verbosity, and code-generation signals.
- Recommendation output must include both: `estimated avoidable tokens` and
  the signal that caused the recommendation.
- Default client selection should include installed/detected local clients, with
  explicit `--client` / `--all` overrides for manual selection.
