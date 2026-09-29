import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { buildSnapshot, compareSnapshots, recordSnapshot } from "../scripts/lib/history.mjs";

function fixture() {
  return {
    report: { meta: { generatedAt: "2026-09-29T12:00:00.000Z", clients: [{
      id: "codex", root: "/secret/raw/logs", status: "ok", files: 1, sessions: 1,
      telemetrySessions: 1, parseErrors: 0, limitReached: false,
    }] }, recommendations: [{ id: "rtk", state: "unknown", verdict: "RECOMMEND",
      signal: "500 shell calls", cost: "Some overhead", breakEven: "Enough shell usage" }] },
    aggregate: { sessions: 1, turns: 2, freshInput: 100, cacheCreate: 0, cacheRead: 100, output: 30, cwd: "/secret/project" },
    sourceId: "ora-agents", days: 30, maxSessions: 400, selectedClients: ["codex"],
  };
}
const snapshot = () => buildSnapshot(fixture());

test("snapshot is a whitelist: no log paths, inventory or prompts", () => {
  const s = snapshot();
  assert.equal(JSON.stringify(s).includes("/secret"), false);
  assert.equal(s.schemaVersion, 1);
  assert.equal(s.recommendations[0].id, "tokenwar:rtk:v1");
  assert.equal(s.metrics.cacheHitRatio, 0.5);
  assert.equal(s.metrics.inputTokensPerTurn, 100);
  assert.equal(s.coverage.status, "complete");
});

test("installed clients with no supported logs stay partial; suspended OpenWiki is absent", () => {
  const input = fixture();
  input.report.meta.clients.push({ id: "opencode", status: "no-logs", files: 0,
    sessions: 0, telemetrySessions: 0, parseErrors: 0, limitReached: false });
  input.report.recommendations.push({ id: "openwiki", state: "unknown", verdict: "NOT YET",
    signal: "none", cost: "none", breakEven: "none" });
  const result = buildSnapshot(input);
  assert.equal(result.coverage.status, "partial");
  assert.equal(result.coverage.clients[1].status, "no-logs");
  assert.equal(result.recommendations.some((item) => item.toolId === "openwiki"), false);
});

test("comparison reports workload deltas without calling them savings", () => {
  const old = snapshot(), next = snapshot();
  next.metrics.inputTokensPerTurn = 50;
  next.metrics.cacheHitRatio = 0.8;
  const c = compareSnapshots(old, next);
  assert.equal(c.status, "comparable");
  assert.equal(c.metrics.inputTokensPerTurn.delta, -50);
  assert.equal(c.metrics.inputTokensPerTurn.direction, "decreased");
  assert.equal(c.metrics.cacheHitRatio.direction, "increased");
  assert.equal(JSON.stringify(c).includes("improved"), false);
});

test("different source, window, clients, sample cap or selection is incomparable", () => {
  for (const mutate of [
    (s) => { s.sourceId = "ora1"; }, (s) => { s.scope.days = 7; },
    (s) => { s.scope.selectedClients = ["claude"]; },
    (s) => { s.scope.maxSessions = 20; }, (s) => { s.scope.selection = "event-time"; },
    (s) => { s.schemaVersion = 2; },
  ]) {
    const next = snapshot(); mutate(next);
    const c = compareSnapshots(snapshot(), next);
    assert.equal(c.status, "incomparable");
    assert.deepEqual(c.metrics, {});
  }
});

test("missing telemetry, truncation, parse errors and missing files are unknown", () => {
  for (const change of [
    { telemetrySessions: 0 }, { limitReached: true }, { parseErrors: 1 },
    { files: 2 }, { status: "unparsed" },
  ]) {
    const input = fixture();
    Object.assign(input.report.meta.clients[0], change);
    const next = buildSnapshot(input);
    assert.equal(next.coverage.status, "partial");
    const comparison = compareSnapshots(snapshot(), next);
    // An unsupported format changes the observed client coverage.
    assert.equal(comparison.status, change.status ? "incomparable" : "unknown");
    if (!change.status) {
      assert.equal(comparison.basis, "observed-partial");
      assert.ok(comparison.metrics.sessions);
      assert.deepEqual(comparison.coverage.current, next.coverage);
    }
  }
});

test("changed observed coverage is incomparable even when client selection matches", () => {
  const old = snapshot(), next = snapshot();
  next.coverage.clients[0].status = "no-logs";
  assert.equal(compareSnapshots(old, next).status, "incomparable");
});

test("missing baseline, reverse dates and zero denominators remain explicit", () => {
  const old = snapshot(), next = snapshot();
  assert.equal(compareSnapshots(null, next).status, "baseline");
  old.generatedAt = "2026-09-30T12:00:00.000Z";
  assert.equal(compareSnapshots(old, next).status, "unknown");
  old.generatedAt = next.generatedAt;
  old.metrics.cacheReadTokens = 0;
  old.metrics.cacheHitRatio = null;
  const c = compareSnapshots(old, next);
  assert.equal(c.metrics.cacheReadTokens.percentChange, null);
  assert.equal(c.metrics.cacheHitRatio.direction, "unknown");
});

test("recommendation changes never imply completed actions", () => {
  const old = snapshot(), next = snapshot();
  next.recommendations = [];
  const change = compareSnapshots(old, next).recommendations[0];
  assert.equal(change.status, "not-assessed");
  assert.equal(change.actionStatus, "unknown");
  next.recommendations = [{ ...old.recommendations[0], observedState: "enabled", verdict: "KEEP" }];
  const updated = compareSnapshots(old, next).recommendations[0];
  assert.equal(updated.status, "changed");
  assert.equal(updated.actionStatus, "unknown");
});

test("local append-only history compares latest source snapshot and uses private files", () => {
  const dir = mkdtempSync(join(tmpdir(), "tokenwar-history-"));
  try {
    const first = recordSnapshot(dir, snapshot());
    const foreign = snapshot(); foreign.sourceId = "ora1";
    recordSnapshot(dir, foreign);
    const next = snapshot(); next.generatedAt = "2026-09-29T13:00:00.000Z";
    const second = recordSnapshot(dir, next);
    assert.equal(first.comparison.status, "baseline");
    assert.equal(second.comparison.previousId, first.id);
    assert.equal(second.comparison.status, "comparable");
    assert.equal(readdirSync(dir).length, 3);
    for (const name of readdirSync(dir)) {
      assert.equal(statSync(join(dir, name)).mode & 0o777, 0o600);
      assert.equal(readFileSync(join(dir, name), "utf8").includes("/secret"), false);
    }
    writeFileSync(join(dir, "damaged.snapshot.json"), "{");
    assert.throws(() => recordSnapshot(dir, snapshot()), SyntaxError);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test("partial trends retain measured changes without assigning improvement", () => {
  const old = snapshot(), next = snapshot();
  next.coverage.status = "partial";
  next.coverage.clients[0].files = 3;
  next.metrics.cacheReadTokens = 200;
  const c = compareSnapshots(old, next);
  assert.equal(c.status, "unknown");
  assert.equal(c.basis, "observed-partial");
  assert.deepEqual(c.reasons, ["incomplete-coverage"]);
  assert.equal(c.metrics.cacheReadTokens.delta, 100);
  assert.equal(c.coverage.previous.clients[0].files, 1);
  assert.equal(c.coverage.current.clients[0].files, 3);
  assert.equal(c.recommendations[0].actionStatus, "unknown");
});
