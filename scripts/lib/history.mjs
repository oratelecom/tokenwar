// Sanitized scanner snapshots. The central API owns recommendation action records.
import { randomUUID } from "node:crypto";
import { mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";

export const SCHEMA_VERSION = 1;
const TOOLS = new Set(["rtk", "context-mode", "graphify", "caveman", "ponytail", "claude-mem", "pxpipe"]);
const METRICS = ["sessions", "turns", "freshInputTokens", "cacheWriteTokens", "cacheReadTokens", "outputTokens", "inputTokensPerTurn", "cacheHitRatio"];
const number = (value) => Number.isFinite(value) && value >= 0 ? value : null;

export function buildSnapshot({ report, aggregate, sourceId, days, maxSessions, selectedClients }) {
  const clients = report.meta.clients.map((client) => ({
    id: client.id, status: client.status, files: client.files, sessions: client.sessions,
    telemetrySessions: client.telemetrySessions || 0,
    parseErrors: client.parseErrors || 0, limitReached: client.limitReached || false,
  })).sort((a, b) => a.id.localeCompare(b.id));
  const complete = clients.some((c) => c.sessions > 0) && clients.every((c) =>
    ["ok", "not-installed"].includes(c.status) &&
    c.files === c.sessions && c.sessions === c.telemetrySessions && !c.parseErrors && !c.limitReached);
  const hasTelemetry = clients.some((c) => c.telemetrySessions > 0);
  const input = aggregate.freshInput + aggregate.cacheCreate + aggregate.cacheRead;
  return {
    schemaVersion: SCHEMA_VERSION, id: randomUUID(), generatedAt: report.meta.generatedAt, sourceId,
    scope: { days, maxSessions, selectedClients: [...selectedClients].sort(), selection: "file-mtime-whole-session-v1" },
    coverage: { status: complete ? "complete" : "partial", clients },
    metrics: {
      sessions: number(aggregate.sessions), turns: number(aggregate.turns),
      freshInputTokens: hasTelemetry ? number(aggregate.freshInput) : null, cacheWriteTokens: hasTelemetry ? number(aggregate.cacheCreate) : null,
      cacheReadTokens: hasTelemetry ? number(aggregate.cacheRead) : null, outputTokens: hasTelemetry ? number(aggregate.output) : null,
      inputTokensPerTurn: hasTelemetry && aggregate.turns > 0 ? number(input / aggregate.turns) : null,
      cacheHitRatio: input > 0 ? number(aggregate.cacheRead / input) : null,
    },
    recommendations: report.recommendations.filter((r) => TOOLS.has(r.id)).map((r) => ({
      id: `tokenwar:${r.id}:v1`, toolId: r.id, verdict: r.verdict,
      observedState: r.state, signal: r.signal, cost: r.cost, breakEven: r.breakEven,
    })),
    limitations: [
      "Rolling windows overlap; selection uses file modification time and includes each session in full.",
      "Usage deltas describe workload; they do not establish savings or an action's causal effect.",
      "No dollar comparison: mixed models and provider tariffs are not reconciled.",
      "Recommendation action completion is recorded by the central API, never inferred from a scan.",
    ],
  };
}

export function compareSnapshots(previous, current) {
  const result = { status: "baseline", previousId: previous?.id || null, reasons: [], basis: null, coverage: null, metrics: {}, recommendations: [] };
  if (!previous) return result;
  if (previous.schemaVersion !== SCHEMA_VERSION || current.schemaVersion !== SCHEMA_VERSION) {
    return { ...result, status: "incomparable", reasons: ["schema-version-changed"] };
  }
  const keys = ["days", "maxSessions", "selection"];
  if (previous.sourceId !== current.sourceId) result.reasons.push("source-changed");
  for (const key of keys) if (previous.scope?.[key] !== current.scope?.[key]) result.reasons.push(`${key}-changed`);
  const clientKey = (s) => JSON.stringify([...(s.scope?.selectedClients || [])].sort());
  if (clientKey(previous) !== clientKey(current)) result.reasons.push("clients-changed");
  if (result.reasons.length) return { ...result, status: "incomparable" };
  const partial = previous.coverage?.status !== "complete" || current.coverage?.status !== "complete";
  const coverageKey = (s) => JSON.stringify(s.coverage.clients.map((c) => [c.id, c.status]).sort());
  if (coverageKey(previous) !== coverageKey(current)) {
    return { ...result, status: "incomparable", reasons: ["client-coverage-changed"] };
  }
  if (!(Date.parse(current.generatedAt) >= Date.parse(previous.generatedAt))) {
    return { ...result, status: "unknown", reasons: ["invalid-report-order"] };
  }
  result.status = partial ? "unknown" : "comparable";
  result.basis = partial ? "observed-partial" : "observed-complete";
  if (partial) result.reasons.push("incomplete-coverage");
  result.coverage = { previous: previous.coverage, current: current.coverage };
  for (const key of METRICS) {
    const before = previous.metrics?.[key], after = current.metrics?.[key];
    const known = number(before) !== null && number(after) !== null;
    const delta = known ? after - before : null;
    result.metrics[key] = {
      previous: number(before), current: number(after), delta,
      percentChange: known && before !== 0 ? delta / before * 100 : null,
      direction: !known ? "unknown" : delta === 0 ? "unchanged" : delta > 0 ? "increased" : "decreased",
    };
  }
  const old = new Map((previous.recommendations || []).map((r) => [r.id, r]));
  const next = new Map((current.recommendations || []).map((r) => [r.id, r]));
  result.recommendations = [...new Set([...old.keys(), ...next.keys()])].sort().map((id) => ({
    id, previousVerdict: old.get(id)?.verdict || null, currentVerdict: next.get(id)?.verdict || null,
    previousState: old.get(id)?.observedState || null, currentState: next.get(id)?.observedState || null,
    status: !old.has(id) ? "new" : !next.has(id) ? "not-assessed" :
      old.get(id).verdict !== next.get(id).verdict || old.get(id).observedState !== next.get(id).observedState ? "changed" : "unchanged",
    actionStatus: "unknown",
  }));
  return result;
}

// Append-only files avoid a shared mutable latest pointer. Fail closed on damaged
// history; silently ignoring a broken newest report would select a false baseline.
export function recordSnapshot(directory, snapshot) {
  mkdirSync(directory, { recursive: true, mode: 0o700 });
  const snapshots = readdirSync(directory).filter((name) => name.endsWith(".snapshot.json")).map((name) =>
    JSON.parse(readFileSync(join(directory, name), "utf8")));
  const previous = snapshots.filter((s) => s.sourceId === snapshot.sourceId)
    .sort((a, b) => b.generatedAt.localeCompare(a.generatedAt))[0] || null;
  const comparison = compareSnapshots(previous, snapshot);
  const result = { ...snapshot, comparison };
  const name = `${snapshot.generatedAt.replaceAll(":", "-")}.${snapshot.id}.snapshot.json`;
  writeFileSync(join(directory, name), JSON.stringify(result, null, 2) + "\n", { mode: 0o600, flag: "wx" });
  return result;
}
