# tokenwar scan

A local audit of what your coding agent loads into every request, measured
against what it actually used.

Inspired by [Yellow Lab Tools](https://github.com/gmetais/YellowLabTools) by
Gaël Métais, which established this shape of audit for web pages: a small set of
graded categories, each backed by the evidence behind its grade. `tokenwar scan`
applies the same idea to an agent session.

Everything runs locally and read-only. No log content leaves the machine.

## Usage

```bash
tokenwar scan                    # audit the last 30 days
tokenwar scan --days 7           # narrow the window
tokenwar scan --html --open      # write an HTML report and open it
tokenwar scan --json             # machine-readable
tokenwar prune                   # what loads every request but is never used
tokenwar bundle devops --dry-run # preview a session-start bundle
```

## What it measures

| Category | Question | Source |
| --- | --- | --- |
| Capability inventory | How many installed skills were ever invoked? | `tool_use` blocks and `attributionSkill` |
| Context-window hygiene | How much of the window is gone before any work? | skill listing sizes on disk |
| Prefix stability | How much input arrives as cache writes rather than reads? | `cache_creation_input_tokens` |
| Cache efficiency | How much of the presented input is served from cache? | `cache_read_input_tokens` |

Token figures come from the provider's own usage fields. The only estimated
numbers are the sizes of on-disk text whose prompt cost we are approximating,
and those are labelled as such.

## The cost model, and why the obvious arithmetic is wrong

The tempting claim is: an unused skill listing costs *N* tokens, a session runs
*T* turns, input is re-sent every turn, therefore it wastes *N × T* tokens.

That is wrong, and it is wrong in the direction that flatters the tool.

A static skill listing sits in the **prompt prefix**, ahead of the conversation.
After the first turn it is served from the prompt cache. Cache reads bill at
**0.1x** base input; cache writes at **1.25x**. So the recurring cost of a
prefix block is:

```
equivalent tokens = N × (1.25 × writes + 0.1 × reads)
```

On a real machine this makes the naive figure roughly **8-9x too high**. On the
logs used to develop this feature, caching was already absorbing **~88%** of the
theoretical waste before any tool was installed. Reporting the pre-cache number
as if it were spend would be a claim the user's own billing page disproves in a
minute, so the report shows both figures and names the gap.

`N × T` does describe something real: how many times the block was *presented*.
It is a token-presentation count, not a bill, and not an amount recoverable by
deleting the skills.

### Where the cost is real

**Context-window occupancy.** Caching discounts price, not space. A cached token
still holds its position in the window on every request, displacing file
contents and reasoning, and bringing compaction forward. Compaction is the
expensive event: it costs an output-priced summarisation pass *and* discards
context.

**Prefix invalidation.** Adding or removing a skill or MCP server changes the
prefix, so it must be rewritten at 1.25x instead of read at 0.1x — a **12.5x**
unit-cost step on every token before the change point.

That second point is why `tokenwar bundle` applies at session start and refuses
to be a mid-session switch: mutating the tool inventory halfway through a large
conversation can cost more to rebuild than the change saves.

## Why the scanner parses structure instead of grepping lines

The earlier implementation counted log **lines** matching regexes such as
`/\b(git|grep|find|cat)\b/i`. That is unsound in ways that all inflate the
numbers:

- A JSONL line is a whole message object carrying several `tool_use` blocks, so
  line counts are neither tool calls nor tokens.
- Every call appears again as a result, double counting it.
- Prose counts as execution: "you should run `git bisect`" scores as a git
  command, and so does documentation quoting one.
- Word boundaries collide: `find` matches `findViewById`, `cat` matches
  `concat`, `gh` matches `light`.
- Reading only the last 512KB samples session *ends*, which are
  verification-heavy, biasing the result rather than merely sampling it.
- Failed, denied and subagent calls score the same as successful user actions.

The current scanner iterates `message.content[]`, deduplicates on `tool_use.id`,
separates sidechain traffic, and recovers `argv[0]` by tokenizing the command —
unwrapping `sudo`, `env`, `timeout` and leading `VAR=value` assignments — so a
command is attributed to the binary that actually ran.

## Workload profile

The scan reports a **distribution over modes with confidence**, never a single
label. Real users mix modes, and a winner-takes-all rule mislabels them.

Inferrable from coding-agent logs: **dev, devops, architect, testing**.

Explicitly **not** inferrable, and reported as such:

- **SEO** — lives in Search Console and content tools. A `curl` against a
  sitemap is indistinguishable from a developer checking a route.
- **Product** — lives in Jira, Linear and meetings. Someone who never opens a
  coding agent leaves no logs. Absence of signal is not signal.
- **Design** — lives in Figma. A `.css` edit means a front-end developer at
  least as often as a designer.

Claiming a seven-way classification from these logs would be unfalsifiable.

## Recommendations

Every recommendation states the observable signal that justifies it, the signal
that rules it out, its own cost, and a break-even rule. Tools whose break-even
is not met are reported as `NOT YET` rather than omitted, and one is reported as
`AVOID`.

Two rules the report enforces on itself:

**Savings are never summed.** RTK, context-mode and caveman act on overlapping
lanes. Adding their individual claims produces a total larger than the spend it
claims to reduce, so overlaps are flagged instead.

**Cost is always modelled.** graphify's graph build spends tokens up front;
openwiki's maintenance is output-priced while the reads it avoids are
cache-read-priced, roughly a 50:1 adverse ratio; claude-mem's injected memory
occupies the same prefix this report measures. A recommendation engine that
models only benefit is an advertisement.

TokenWar recommends tools maintained by its own authors. The arithmetic is shown
so every recommendation can be checked.

## Bundles

```bash
tokenwar bundle dev|devops|architect|testing
```

| Bundle | Enables | Disables | Rationale |
| --- | --- | --- | --- |
| dev | rtk, caveman, ponytail, claude-mem | pxpipe | Shell output and generated code dominate |
| devops | rtk, caveman | graphify, pxpipe | Shell stdout is the whole cost; no repo to index |
| architect | graphify, claude-mem, caveman | pxpipe | Discovery sweeps repeat across sessions |
| testing | rtk, caveman | graphify, pxpipe | High-volume compressible output; exactness matters |

Apply at the start of a session, for the invalidation reason above.

## Multi-client support

Each agent stores sessions differently, so each needs its own adapter. The
report always lists which clients it actually read, and distinguishes a client
that had no sessions from one whose format could not be parsed — an unread
client must never be mistaken for an efficient one.

| Client | Log location | Token telemetry | Status |
| --- | --- | --- | --- |
| Claude Code | `~/.claude/projects/**/*.jsonl` | Yes | Full support |
| Codex | `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` | Yes | Full support |
| Gemini CLI | `~/.gemini/tmp/<hash>/logs.json` | No | Tool evidence only, excluded from cost |
| GitHub Copilot CLI | `~/.copilot/**` | Expected | Adapter pending real session logs |
| opencode | `~/.local/share/opencode/**` | Expected | Adapter pending real session logs |

Codex reports cumulative totals in periodic `token_count` events, so a turn's
cost is the delta between successive snapshots. Its `input_tokens` already
includes the cached portion, which is subtracted so the same tokens are not
counted as both fresh and cached.

Scan one client with `--client codex`, or all detected ones by default.

Skills and MCP servers are Claude Code capabilities, so their listing cost is
priced against Claude turns only, never against turns from a client that never
carried them.

## Limits

- MCP tool counts are only knowable from a live session; pass them via
  `TOKENWAR_MCP_TOOL_COUNTS` or they show as unknown.
- Copilot and opencode are detected but have no adapter yet; they report
  `format unsupported` rather than contributing zero.
- Gemini's local logs carry no usage fields, so it contributes tool evidence
  but is excluded from every cost figure.
- Cache TTL expiry during idle gaps is invisible in logs, so the cached cost is
  a floor rather than an exact figure.
- Only Claude Code writes `.jsonl` sessions in the parsed schema today. Other
  clients are detected but contribute less structured detail.
- "Never invoked in the window" is not "unwanted": a release skill used twice a
  year still earns its listing cost. `tokenwar prune` prints a review list and
  deletes nothing.

## Sanitized snapshots and report history

For a central API or another consumer, request the versioned aggregate contract:

```bash
TOKENWAR_SCAN_SKIP_STATUS=1 tokenwar scan --summary-json --source-id ora-agents --days 30 --max-sessions 400
tokenwar scan --summary-json --source-id ora-agents --client codex --history ~/.local/state/tokenwar/history
```

The summary explicitly projects numeric telemetry, client coverage and the known
recommendations. It excludes session paths, prompts, command arguments, tool
results, skill names and inventory sources. It makes no network request.
`TOKENWAR_SCAN_SKIP_STATUS=1` also skips status subprocesses; recommendation
tool states then remain unknown. Ordinary `--json` remains the detailed local
report and is **not** the upload contract.

Snapshot schema version 1 contains `id`, `generatedAt`, `sourceId`, `scope`,
`coverage`, `metrics`, `recommendations`, `limitations` and `comparison`.
The scope records selected clients, duration, session cap and selection method.
The current method selects files by modification time, then includes each whole
session: these are not exact event-time windows. Metrics include fresh input,
cache writes, cache reads, output, input per turn and cache hit ratio; dollar
comparisons are excluded because mixed models and provider tariffs need separate
reconciliation.

`scripts/lib/history.mjs` exports pure `buildSnapshot` and `compareSnapshots`.
Comparisons return `baseline` with no previous report, `incomparable` when
source, schema, window duration, client selection or sampling settings differ,
and `unknown` for incomplete coverage. Comparable scopes retain observed
metric deltas under `basis: "observed-partial"`, with previous/current coverage
counts, even when coverage is incomplete. These deltas must be shown neutrally,
without improvement colors or an inference about recommendation efficacy. Truncation, parse errors, unread files
and clients without token telemetry make coverage partial. Metrics show numeric
changes and increased/decreased/unchanged directions, never causal savings.
A zero baseline has no percentage change; an unknown ratio is null.

Recommendations have stable IDs such as `tokenwar:rtk:v1`. Changes show observed
verdicts and states. A disappearing recommendation is `not-assessed`; action
completion always remains unknown to the scanner. The central API owns
recommendation action records and is the source of truth for the board.

Optional `--history DIR` writes private append-only sanitized snapshot files
(mode 0600), compares with the latest snapshot for the same source, and fails
explicitly if history is corrupt. Run one collector per source to keep a serial
history. No history files are written unless this flag is supplied.

Validation: `bats tests/history.bats tests/scan.bats tests/parse.bats`.
Central Ora integration should expose this same coverage, report comparison and
action-tracking capability on its existing `/tests` page.

On GCP, a seven-day scan with a 3,200-file cap per client took 27 seconds
and approximately 800 MiB peak RAM across Claude and Codex logs. Allow 90 seconds
for remote collection and adequate host memory; this is an observed benchmark,
not a runtime guarantee. Whole-file parsing currently retains normalized
session data for the selected sample.

An installed client with no supported session files has **partial coverage**: other stores may contain sessions. The sanitized summary excludes OpenWiki while it is suspended.
