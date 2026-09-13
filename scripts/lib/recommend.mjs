// Recommendation engine.
//
// Every recommendation must name the observable signal that justifies it, the
// signal that would rule it out, and its own cost. A tool that only models
// benefit is an advertisement, so tools whose break-even is not met here are
// reported as NOT recommended rather than quietly omitted.
//
// Overlapping lanes are never summed: RTK, context-mode and caveman all touch
// output volume, and adding their individual claims produces a total larger
// than the spend it claims to reduce.

import { CACHE_READ_MULTIPLIER, dollars } from "./economics.mjs";
import { CHARS_PER_TOKEN } from "./inventory.mjs";

export const VERDICT = {
  RECOMMEND: "RECOMMEND",
  KEEP: "KEEP",
  NOT_YET: "NOT YET",
  AVOID: "AVOID",
};

// Lanes each tool acts on. Used to detect double-counting between tools.
const TOOL_LANES = {
  rtk: ["shell", "test"],
  "context-mode": ["shell", "web", "fileRead", "mcp"],
  graphify: ["search", "fileRead", "read"],
  caveman: ["output"],
  ponytail: ["code"],
  "claude-mem": ["prefix"],
  pxpipe: ["prefix"],
  openwiki: ["search", "fileRead"],
};

function tokensFromBytes(bytes) {
  return Math.round(bytes / CHARS_PER_TOKEN);
}

// A tool result enters context once as a cache write, then is re-read on each
// later turn of that session. Value it accordingly rather than at fresh-input
// price, which would overstate it by roughly an order of magnitude.
function laneValue(tokens, price, turnsRemaining) {
  const write = dollars(tokens, price.input * 1.25);
  const reads = dollars(tokens * Math.max(0, turnsRemaining), price.input * CACHE_READ_MULTIPLIER);
  return write + reads;
}

export function buildRecommendations({ aggregate, price, profile, toolStates = {}, avgTurns = 20 }) {
  const lanes = aggregate.lanes;
  const state = (id) => toolStates[id] || "unknown";
  const enabled = (id) => state(id) === "OK" || state(id) === "enabled";

  const shellTokens = tokensFromBytes(lanes.shell.bytes + lanes.test.bytes);
  const discoveryTokens = tokensFromBytes(lanes.search.bytes + lanes.read.bytes + lanes.fileRead.bytes);
  const heavyTokens = tokensFromBytes(lanes.web.bytes + lanes.mcp.bytes);
  const proseTokens = Math.round(aggregate.assistantProseChars / CHARS_PER_TOKEN);
  const codeTokens = Math.round(aggregate.codeWrittenChars / CHARS_PER_TOKEN);

  const totalToolCalls = [...aggregate.toolCalls.values()].reduce((sum, value) => sum + value, 0) || 1;
  const bashShare = aggregate.bashCount / totalToolCalls;
  const discoveryCalls = lanes.search.calls + lanes.read.calls + lanes.fileRead.calls;

  // Half the session's turns is the expected re-read horizon for a payload
  // landing at an arbitrary point in the session.
  const horizon = Math.max(1, Math.round(avgTurns / 2));

  const items = [];

  // RTK — compresses shell stdout at the hook level.
  {
    const value = laneValue(shellTokens, price, horizon);
    const meets = bashShare >= 0.30 && shellTokens >= 20000;
    items.push({
      id: "rtk",
      tool: "RTK",
      lane: "shell/tool stdout",
      state: state("rtk"),
      verdict: enabled("rtk") ? VERDICT.KEEP : meets ? VERDICT.RECOMMEND : VERDICT.NOT_YET,
      signal: `${aggregate.bashCount} shell calls (${(bashShare * 100).toFixed(0)}% of tool calls), ${shellTokens.toLocaleString()} tok of stdout`,
      counterSignal: "Shell under 20% of calls, or results already small.",
      cost: "Sub-10ms per call. Risk: eliding output the model needed.",
      breakEven: "Positive above roughly 30% shell share; no index to build.",
      valueDollars: value,
      lanesTouched: TOOL_LANES.rtk,
    });
  }

  // caveman — compresses the model's own prose. Output is priced ~5x input and
  // is never discounted by caching, so this lane is worth more per token than
  // its raw volume suggests.
  {
    const value = dollars(proseTokens * 0.65, price.output);
    const outputShare = aggregate.output > 0 ? aggregate.output / (aggregate.output + aggregate.freshInput + aggregate.cacheCreate) : 0;
    const meets = proseTokens >= 50000;
    items.push({
      id: "caveman",
      tool: "caveman",
      lane: "model prose (output tokens)",
      state: state("caveman"),
      verdict: enabled("caveman") ? VERDICT.KEEP : meets ? VERDICT.RECOMMEND : VERDICT.NOT_YET,
      signal: `${proseTokens.toLocaleString()} tok of assistant prose; output is ${(outputShare * 100).toFixed(1)}% of billed volume at ${price.output}/M`,
      counterSignal: "Client-facing prose, or work where wording precision matters.",
      cost: "Readability. An independent benchmark (ponytail's) measured caveman at +7% tokens, so the 65% claim is not third-party replicated.",
      breakEven: "Output spend x compression rate. Never the headline; output is the smaller pool.",
      valueDollars: value,
      lanesTouched: TOOL_LANES.caveman,
    });
  }

  // context-mode — sandboxes heavy payloads so raw bytes stay out of context.
  {
    const value = laneValue(heavyTokens + shellTokens * 0.3, price, horizon);
    const meets = heavyTokens >= 10000 || shellTokens >= 50000;
    items.push({
      id: "context-mode",
      tool: "context-mode",
      lane: "heavy data (web, MCP, large reads)",
      state: state("context-mode"),
      verdict: enabled("context-mode") ? VERDICT.KEEP : meets ? VERDICT.RECOMMEND : VERDICT.NOT_YET,
      signal: `${heavyTokens.toLocaleString()} tok from web/MCP payloads, ${lanes.web.calls + lanes.mcp.calls} calls`,
      counterSignal: "Outputs already small, or exact bytes needed for Edit matching.",
      cost: "Sandbox spawn per call. Licence: Elastic License 2.0, not OSI-approved; last human commit 2026-06-29.",
      breakEven: "Positive when result tokens exceed the derived answer plus overhead.",
      valueDollars: value,
      lanesTouched: TOOL_LANES["context-mode"],
      warning: "ELv2 licence blocks adoption in foundation/corporate OSS contexts; human development appears stalled.",
    });
  }

  // graphify — replaces repeated discovery sweeps with bounded graph queries.
  // Build cost is real, so this needs sustained sweep volume to pay back.
  {
    const value = laneValue(discoveryTokens, price, horizon);
    const meets = discoveryCalls >= 200 && discoveryTokens >= 150000;
    items.push({
      id: "graphify",
      tool: "graphify",
      lane: "repo discovery (search + file reads)",
      state: state("graphify"),
      verdict: enabled("graphify") ? VERDICT.KEEP : meets ? VERDICT.RECOMMEND : VERDICT.NOT_YET,
      signal: `${discoveryCalls} discovery calls, ${discoveryTokens.toLocaleString()} tok of search/read output`,
      counterSignal: "Few sweeps, small repo, or fast-churning code where the graph goes stale.",
      cost: "Graph build spends tokens up front and must be rebuilt on drift. Its own README notes ~1x gain on a 6-file corpus.",
      breakEven: "build + rebuilds < queries x mean sweep cost. Needs sustained sweeping on a stable repo.",
      valueDollars: value,
      lanesTouched: TOOL_LANES.graphify,
    });
  }

  // claude-mem — cross-session memory. Its own injection sits in the prefix, so
  // it can worsen the occupancy problem this scan exists to measure.
  {
    const repeatProjects = aggregate.cwds.size > 0 && aggregate.sessions / aggregate.cwds.size >= 3;
    const meets = repeatProjects && aggregate.sessions >= 10;
    items.push({
      id: "claude-mem",
      tool: "claude-mem",
      lane: "cross-session memory",
      state: state("claude-mem"),
      verdict: enabled("claude-mem") ? VERDICT.KEEP : meets ? VERDICT.RECOMMEND : VERDICT.NOT_YET,
      signal: `${aggregate.sessions} sessions across ${aggregate.cwds.size} projects (${(aggregate.sessions / Math.max(1, aggregate.cwds.size)).toFixed(1)} per project)`,
      counterSignal: "One-off projects, or an injected memory block larger than the re-priming it avoids.",
      cost: "Injected memory occupies the prefix permanently, the same 1.0x window cost being diagnosed here. Compression itself spends tokens.",
      breakEven: "injected memory tokens < re-explanation tokens saved per session. Must be measured, not assumed.",
      valueDollars: 0,
      valueUnknown: true,
      lanesTouched: TOOL_LANES["claude-mem"],
      warning: "Can worsen the window-occupancy metric it is meant to help. Measure before and after.",
    });
  }

  // ponytail — fewer lines of generated code; saves at generation and on every
  // later read of the smaller file.
  {
    const value = dollars(codeTokens * 0.2, price.output);
    const meets = codeTokens >= 30000;
    items.push({
      id: "ponytail",
      tool: "ponytail",
      lane: "generated code",
      state: state("ponytail"),
      verdict: enabled("ponytail") ? VERDICT.KEEP : meets ? VERDICT.RECOMMEND : VERDICT.NOT_YET,
      signal: `${codeTokens.toLocaleString()} tok of code written`,
      counterSignal: "Little code generation, or a terse reasoning model where the ruleset can backfire.",
      cost: "Near zero: a ruleset injected via hooks.",
      breakEven: "Positive whenever meaningful code is generated; saving recurs on every later read.",
      valueDollars: value,
      lanesTouched: TOOL_LANES.ponytail,
    });
  }

  // pxpipe — renders prompt payload as PNG at the provider boundary. Flagged
  // rather than recommended: it trades exactness, and it disturbs the cache
  // prefix that this analysis shows is the dominant cost driver.
  {
    items.push({
      id: "pxpipe",
      tool: "pxpipe",
      lane: "provider-bound prompt payload",
      state: state("pxpipe"),
      verdict: VERDICT.AVOID,
      signal: `Not justified by this log profile.`,
      counterSignal: "Any workload needing exact string recall: stack traces, diffs, log greps, code.",
      cost: "Its README caps blind exact-recall at 63% on dense documents. Image tokens are not free, and changing the payload representation can disturb prompt-cache reuse.",
      breakEven: "image tokens < text tokens x (1 - fidelity risk). Narrow, and negative for code-heavy work.",
      valueDollars: 0,
      lanesTouched: TOOL_LANES.pxpipe,
      warning: "Most likely tool in the stack to be net-negative while appearing clever.",
    });
  }

  // openwiki — maintained docs. Maintenance is output-priced while the reading
  // it saves is cache-read-priced, a 50:1 adverse ratio.
  {
    const ratio = price.output / (price.input * CACHE_READ_MULTIPLIER);
    const meets = aggregate.sessions >= 20 && discoveryCalls >= 300;
    items.push({
      id: "openwiki",
      tool: "openwiki",
      lane: "maintained documentation",
      state: state("openwiki"),
      verdict: meets ? VERDICT.NOT_YET : VERDICT.NOT_YET,
      signal: `${discoveryCalls} discovery calls across ${aggregate.cwds.size} projects`,
      counterSignal: "Solo work, or docs maintained more often than read.",
      cost: `Maintenance is output-priced (${price.output}/M) while the reads it avoids are cache-read-priced (${(price.input * CACHE_READ_MULTIPLIER).toFixed(2)}/M) - a ${ratio.toFixed(0)}:1 adverse ratio.`,
      breakEven: `Needs roughly ${ratio.toFixed(0)} avoided read-tokens per maintenance token. Rarely met on solo work.`,
      valueDollars: 0,
      valueUnknown: true,
      lanesTouched: TOOL_LANES.openwiki,
      warning: "Upstream makes no token-saving claim; it is a documentation tool, not a compressor.",
    });
  }

  // Flag overlaps so a reader is never invited to add two figures that both
  // describe the same bytes.
  const recommended = items.filter((item) => item.verdict === VERDICT.RECOMMEND || item.verdict === VERDICT.KEEP);
  const overlaps = [];
  for (let i = 0; i < recommended.length; i += 1) {
    for (let j = i + 1; j < recommended.length; j += 1) {
      const shared = recommended[i].lanesTouched.filter((lane) => recommended[j].lanesTouched.includes(lane));
      if (shared.length > 0) {
        overlaps.push({ a: recommended[i].tool, b: recommended[j].tool, lanes: shared });
      }
    }
  }

  items.sort((left, right) => {
    const order = { [VERDICT.RECOMMEND]: 0, [VERDICT.KEEP]: 1, [VERDICT.NOT_YET]: 2, [VERDICT.AVOID]: 3 };
    if (order[left.verdict] !== order[right.verdict]) return order[left.verdict] - order[right.verdict];
    return (right.valueDollars || 0) - (left.valueDollars || 0);
  });

  return { items, overlaps };
}

// Session-start bundles. Deliberately chosen at launch, never mid-session:
// mutating the tool inventory invalidates the cache prefix, so a switch can
// cost more to rebuild than the change saves.
export const BUNDLES = {
  dev: {
    label: "Development",
    enable: ["rtk", "caveman", "ponytail", "claude-mem"],
    disable: ["pxpipe"],
    why: "Shell output and generated code dominate. Memory pays back across repeated sessions on one repo.",
  },
  devops: {
    label: "Ops / infrastructure",
    enable: ["rtk", "caveman"],
    disable: ["graphify", "openwiki", "pxpipe"],
    why: "Shell stdout is the whole cost. Repo graphs and wikis have nothing to index against infrastructure work.",
  },
  architect: {
    label: "Architecture / discovery",
    enable: ["graphify", "claude-mem", "caveman"],
    disable: ["pxpipe"],
    why: "Discovery sweeps dominate, and they repeat across sessions, which is exactly what a graph and memory amortise.",
  },
  testing: {
    label: "Testing",
    enable: ["rtk", "caveman"],
    disable: ["graphify", "openwiki", "pxpipe"],
    why: "Test output is high-volume and highly compressible. Exactness matters, so no lossy payload rendering.",
  },
};
