// Cache-aware cost model.
//
// The rule this module exists to enforce: a static block sitting in the prompt
// prefix is cached, so its recurring cost is a cache READ (0.1x), not a fresh
// input token (1.0x). Multiplying a prefix block by the turn count overstates
// the bill by roughly 9x. What that multiplication does describe is how often
// the block was presented, which is a context-window fact, not a billing one.

// Multipliers are the provider's, relative to base input price.
export const CACHE_READ_MULTIPLIER = 0.1;
export const CACHE_WRITE_5M_MULTIPLIER = 1.25;
export const CACHE_WRITE_1H_MULTIPLIER = 2.0;

// Per million tokens, base input/output. Used only when the caller does not
// supply its own; every figure derived from these is labelled with the model.
export const PRICING = {
  "claude-opus": { input: 15, output: 75, contextWindow: 200000 },
  "claude-sonnet": { input: 3, output: 15, contextWindow: 200000 },
  "claude-haiku": { input: 1, output: 5, contextWindow: 200000 },
};

export const DEFAULT_MODEL = "claude-sonnet";

export function pricingFor(model) {
  if (model && PRICING[model]) return { id: model, ...PRICING[model] };
  // Match a full model id (claude-opus-5[1m], claude-sonnet-5, ...) to a family.
  if (typeof model === "string") {
    for (const key of Object.keys(PRICING)) {
      if (model.includes(key.replace("claude-", ""))) return { id: key, ...PRICING[key] };
    }
  }
  return { id: DEFAULT_MODEL, ...PRICING[DEFAULT_MODEL] };
}

export function dollars(tokens, perMillion) {
  return (tokens / 1_000_000) * perMillion;
}

// Actual spend from provider-reported usage. No estimation.
export function observedCost(usage, price) {
  const input = dollars(usage.freshInput || 0, price.input);
  const write = dollars(usage.cacheCreate || 0, price.input * CACHE_WRITE_5M_MULTIPLIER);
  const read = dollars(usage.cacheRead || 0, price.input * CACHE_READ_MULTIPLIER);
  const output = dollars(usage.output || 0, price.output);
  return { input, write, read, output, total: input + write + read + output };
}

// What the same volume would have cost with no caching at all. Used to show how
// much of the theoretical waste caching already absorbs, so the report never
// takes credit for a saving the provider is already giving.
export function uncachedCost(usage, price) {
  const presented = (usage.freshInput || 0) + (usage.cacheCreate || 0) + (usage.cacheRead || 0);
  return dollars(presented, price.input) + dollars(usage.output || 0, price.output);
}

// Cost of a static prefix block (a skill listing, an MCP schema set) across a
// session. Returns both the naive and the cache-adjusted number so a report can
// show the gap rather than quietly pick the flattering one.
export function prefixBlockCost({ blockTokens, turns, price, cacheWriteTurns = 1 }) {
  const naiveTokens = blockTokens * turns;
  const naiveDollars = dollars(naiveTokens, price.input);

  // The block is written once per prefix rebuild and read on every other turn.
  // `cacheWriteTurns` must count rebuilds that actually re-send THIS block —
  // i.e. cold starts and inventory changes. Turns that merely append to the
  // conversation tail rewrite a later cache segment, leaving the static prefix
  // (and this block) still served as a read.
  const writes = Math.max(1, Math.min(cacheWriteTurns, turns));
  const reads = Math.max(0, turns - writes);
  const equivalentTokens =
    blockTokens * (writes * CACHE_WRITE_5M_MULTIPLIER + reads * CACHE_READ_MULTIPLIER);
  const cachedDollars =
    dollars(blockTokens * writes, price.input * CACHE_WRITE_5M_MULTIPLIER) +
    dollars(blockTokens * reads, price.input * CACHE_READ_MULTIPLIER);

  return {
    blockTokens,
    turns,
    naiveTokens,
    naiveDollars,
    equivalentTokens: Math.round(equivalentTokens),
    cachedDollars,
    overstatementFactor: cachedDollars > 0 ? naiveDollars / cachedDollars : 0,
    writes,
    reads,
  };
}

// Context-window occupancy. This is the cost caching does NOT discount: a
// cached token still holds its position in the window and still brings
// compaction forward.
export function windowOccupancy({ blockTokens, contextWindow, firstRequestTokens }) {
  return {
    blockTokens,
    contextWindow,
    windowShare: contextWindow ? blockTokens / contextWindow : 0,
    firstRequestShare: firstRequestTokens ? blockTokens / firstRequestTokens : 0,
  };
}

// Cost of one prefix invalidation: the prefix is rewritten at 1.25x instead of
// read at 0.1x, a 12.5x step on every token before the change point.
export function invalidationCost({ prefixTokens, price }) {
  const rewrite = dollars(prefixTokens, price.input * CACHE_WRITE_5M_MULTIPLIER);
  const read = dollars(prefixTokens, price.input * CACHE_READ_MULTIPLIER);
  return { prefixTokens, rewrite, read, penalty: rewrite - read };
}

export function formatTokens(tokens) {
  const value = Math.round(tokens);
  if (Math.abs(value) >= 1_000_000) return `${(value / 1_000_000).toFixed(1)}M`;
  if (Math.abs(value) >= 1_000) return `${(value / 1_000).toFixed(1)}K`;
  return String(value);
}

export function formatDollars(amount) {
  if (amount === 0) return "$0.00";
  if (Math.abs(amount) < 0.01) return `$${amount.toFixed(4)}`;
  return `$${amount.toFixed(2)}`;
}

export function formatPercent(ratio, digits = 1) {
  return `${(ratio * 100).toFixed(digits)}%`;
}
