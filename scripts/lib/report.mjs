// Report rendering: terminal and HTML.
//
// The grading model is borrowed from Yellow Lab Tools (gmetais/yellowlabtools),
// which pioneered this shape of audit for web pages: a small number of graded
// categories, each with the evidence behind the grade.

import { formatTokens, formatDollars, formatPercent } from "./economics.mjs";

const BOLD = "[1m";
const DIM = "[2m";
const RESET = "[0m";
const RED = "[31m";
const GREEN = "[32m";
const YELLOW = "[33m";
const BLUE = "[36m";

const useColor = process.stdout.isTTY && !process.env.NO_COLOR;
const c = (code, text) => (useColor ? `${code}${text}${RESET}` : String(text));

export function grade(score) {
  if (score >= 90) return { letter: "A", color: GREEN };
  if (score >= 75) return { letter: "B", color: GREEN };
  if (score >= 60) return { letter: "C", color: YELLOW };
  if (score >= 40) return { letter: "D", color: YELLOW };
  return { letter: "E", color: RED };
}

// Scores are deliberately simple and explainable: each is a direct function of
// one measured quantity, so a reader can always see what would move it.
export function computeScores({ inventory, occupancy, cacheStats }) {
  const skills = inventory.skills;
  const deadRatio = skills.all.length ? skills.dead.length / skills.all.length : 0;
  const inventoryScore = Math.round((1 - deadRatio) * 100);

  const windowScore = Math.round(Math.max(0, 1 - occupancy.windowShare / 0.10) * 100);

  // Prefix stability is about how expensive an inventory change is, not about
  // ordinary conversation growth (which writes cache on nearly every turn by
  // design). Score the penalty a change would cost, relative to a session.
  const churnRatio = cacheStats.turns > 0 ? cacheStats.cacheWriteTurns / cacheStats.turns : 0;
  const rewriteShare = cacheStats.presented > 0 ? cacheStats.cacheCreate / cacheStats.presented : 0;
  const stabilityScore = Math.round(Math.max(0, 1 - rewriteShare / 0.05) * 100);

  const hitRatio = cacheStats.presented > 0 ? cacheStats.cacheRead / cacheStats.presented : 0;
  const cacheScore = Math.round(hitRatio * 100);

  return {
    inventory: { score: inventoryScore, label: "Capability inventory", detail: `${skills.dead.length}/${skills.all.length} skills never invoked` },
    window: { score: windowScore, label: "Context-window hygiene", detail: `${formatPercent(occupancy.windowShare)} of the window occupied before any work` },
    stability: { score: stabilityScore, label: "Prefix stability", detail: `${formatPercent(rewriteShare)} of input is cache writes; ${formatPercent(churnRatio)} of turns pay one` },
    cache: { score: cacheScore, label: "Cache efficiency", detail: `${formatPercent(hitRatio)} of presented input served from cache` },
    overall: Math.round((inventoryScore + windowScore + stabilityScore + cacheScore) / 4),
  };
}

function bar(ratio, width = 24) {
  const filled = Math.round(Math.min(1, Math.max(0, ratio)) * width);
  return "█".repeat(filled) + "░".repeat(width - filled);
}

export function renderTerminal(report) {
  const out = [];
  const { meta, scores, inventory, occupancy, cacheStats, prefixCost, profile, recommendations, overlaps } = report;

  out.push("");
  out.push(c(BOLD, "  TOKENWAR SCAN") + c(DIM, `  ${meta.sessions} sessions · ${meta.turns.toLocaleString()} turns · ${meta.window}`));
  out.push(c(DIM, "  " + "─".repeat(72)));
  out.push("");

  const overall = grade(scores.overall);
  out.push(`  ${c(BOLD, "Overall")}  ${c(overall.color, overall.letter)}  ${c(DIM, `${scores.overall}/100`)}`);
  out.push("");

  for (const key of ["inventory", "window", "stability", "cache"]) {
    const item = scores[key];
    const g = grade(item.score);
    out.push(`  ${c(g.color, g.letter)}  ${item.label.padEnd(24)} ${c(DIM, bar(item.score / 100))} ${String(item.score).padStart(3)}`);
    out.push(`     ${c(DIM, item.detail)}`);
  }
  out.push("");

  // Dead weight — the part that needs no modelling.
  out.push(c(BOLD, "  DEAD WEIGHT") + c(DIM, "  measured, not estimated"));
  out.push("");
  out.push(`    ${c(BOLD, String(inventory.skills.dead.length))} of ${inventory.skills.all.length} skills never invoked, costing ${c(BOLD, formatTokens(inventory.skills.deadListingTokens))} tokens on every request`);
  if (inventory.mcp.dead.length > 0) {
    const deadTools = inventory.mcp.dead.reduce((sum, s) => sum + (s.toolCount || 0), 0);
    out.push(`    ${c(BOLD, String(inventory.mcp.dead.length))} MCP servers never called${deadTools ? ` (${deadTools} tools exposed)` : ""}: ${inventory.mcp.dead.map((s) => s.name).join(", ")}`);
  }
  out.push("");

  // The honest cost framing.
  out.push(c(BOLD, "  WHAT THAT ACTUALLY COSTS"));
  out.push("");
  out.push(`    If input were re-sent uncached      ${formatTokens(prefixCost.naiveTokens).padStart(9)} tok   ${formatDollars(prefixCost.naiveDollars).padStart(9)}`);
  out.push(`    ${c(GREEN, "Real, prefix served from cache")}     ${formatTokens(prefixCost.equivalentTokens).padStart(9)} tok   ${c(GREEN, formatDollars(prefixCost.cachedDollars).padStart(9))}`);
  out.push(`    ${c(DIM, `The uncached figure overstates cost ${prefixCost.overstatementFactor.toFixed(1)}x. Those ${formatTokens(prefixCost.naiveTokens)} are token-presentations,`)}`);
  out.push(`    ${c(DIM, "not tokens billed and not tokens you would recover by deleting the skills.")}`);
  out.push("");
  out.push(`    ${c(YELLOW, "But caching discounts price, not space:")}`);
  out.push(`      ${formatTokens(occupancy.blockTokens)} tok = ${c(BOLD, formatPercent(occupancy.windowShare))} of the ${formatTokens(occupancy.contextWindow)} window, permanently`);
  out.push(`      ${c(BOLD, formatPercent(occupancy.firstRequestShare))} of a median first request`);
  out.push(`      ${formatPercent(cacheStats.cacheWriteTurns / Math.max(1, cacheStats.turns))} of turns pay a cache write (mean ${formatTokens(cacheStats.meanRewrite)} tok, ${formatDollars(cacheStats.rewriteDollars)} total).`);
  out.push(`      ${c(DIM, "Most of that is the conversation growing. But changing the installed set")}`);
  out.push(`      ${c(DIM, `invalidates the static prefix too: ${formatDollars(cacheStats.invalidationPenalty)} to rebuild at a typical mid-session size.`)}`);
  out.push("");

  // Profile.
  out.push(c(BOLD, "  WORKLOAD PROFILE"));
  out.push("");
  if (profile.distribution.length === 0) {
    out.push(`    ${c(DIM, "Not enough evidence to infer a workload mode.")}`);
  } else {
    for (const item of profile.distribution) {
      out.push(`    ${item.mode.padEnd(12)} ${c(BLUE, bar(item.confidence, 16))} ${formatPercent(item.confidence, 0).padStart(5)}`);
      for (const evidence of item.evidence.slice(0, 2)) {
        out.push(`      ${c(DIM, evidence.why)}`);
      }
    }
    if (!profile.determinate) {
      out.push(`    ${c(YELLOW, "Confidence is low — confirm the mode rather than trusting this label.")}`);
    }
  }
  out.push(`    ${c(DIM, "Not inferrable from coding-agent logs: SEO, product, design.")}`);
  out.push("");

  // Recommendations.
  out.push(c(BOLD, "  RECOMMENDATIONS"));
  out.push("");
  const verdictColor = { RECOMMEND: GREEN, KEEP: BLUE, "NOT YET": DIM, AVOID: RED };
  for (const item of recommendations) {
    const color = verdictColor[item.verdict] || DIM;
    const value = item.valueUnknown ? "needs measuring" : formatDollars(item.valueDollars);
    out.push(`    ${c(color, item.verdict.padEnd(10))} ${c(BOLD, item.tool.padEnd(14))} ${c(DIM, item.lane)}`);
    out.push(`      ${c(DIM, "signal:")} ${item.signal}`);
    if (item.verdict === "RECOMMEND" || item.verdict === "KEEP") {
      out.push(`      ${c(DIM, "lane value:")} ${value}   ${c(DIM, item.breakEven)}`);
    } else {
      out.push(`      ${c(DIM, "why not:")} ${item.breakEven}`);
    }
    if (item.warning) out.push(`      ${c(YELLOW, "! " + item.warning)}`);
    out.push("");
  }

  if (overlaps.length > 0) {
    out.push(c(YELLOW, "  Overlapping lanes — do not add these savings together:"));
    for (const overlap of overlaps) {
      out.push(`    ${overlap.a} + ${overlap.b} both act on: ${overlap.lanes.join(", ")}`);
    }
    out.push("");
  }

  out.push(c(DIM, "  Figures come from provider-reported usage fields, not estimates."));
  out.push(c(DIM, "  Inspired by Yellow Lab Tools (gmetais/yellowlabtools)."));
  out.push("");

  return out.join("\n");
}

function escapeHtml(text) {
  return String(text).replace(/[&<>"']/g, (ch) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[ch]));
}

export function renderHtml(report) {
  const { meta, scores, inventory, occupancy, cacheStats, prefixCost, profile, recommendations, overlaps } = report;
  const gradeOf = (score) => grade(score).letter;

  const scoreCards = ["inventory", "window", "stability", "cache"]
    .map((key) => {
      const item = scores[key];
      return `<div class="card">
        <div class="grade g${gradeOf(item.score)}">${gradeOf(item.score)}</div>
        <div class="card-body">
          <h3>${escapeHtml(item.label)}</h3>
          <div class="meter"><span style="width:${item.score}%"></span></div>
          <p>${escapeHtml(item.detail)}</p>
        </div>
      </div>`;
    })
    .join("\n");

  const profileRows = profile.distribution.length
    ? profile.distribution
        .map(
          (item) => `<tr>
            <td class="mode">${escapeHtml(item.mode)}</td>
            <td class="conf"><div class="meter"><span style="width:${(item.confidence * 100).toFixed(0)}%"></span></div></td>
            <td class="num">${formatPercent(item.confidence, 0)}</td>
            <td class="why">${item.evidence.map((e) => escapeHtml(e.why)).join("<br>")}</td>
          </tr>`
        )
        .join("\n")
    : `<tr><td colspan="4">Not enough evidence to infer a workload mode.</td></tr>`;

  const recRows = recommendations
    .map(
      (item) => `<tr class="v-${item.verdict.replace(/\s+/g, "-").toLowerCase()}">
        <td><span class="verdict">${escapeHtml(item.verdict)}</span></td>
        <td class="tool">${escapeHtml(item.tool)}<div class="lane">${escapeHtml(item.lane)}</div></td>
        <td class="detail">
          <div><strong>Signal</strong> ${escapeHtml(item.signal)}</div>
          <div><strong>Cost</strong> ${escapeHtml(item.cost)}</div>
          <div><strong>Break-even</strong> ${escapeHtml(item.breakEven)}</div>
          ${item.warning ? `<div class="warn">${escapeHtml(item.warning)}</div>` : ""}
        </td>
        <td class="num">${item.valueUnknown ? "—" : formatDollars(item.valueDollars)}</td>
      </tr>`
    )
    .join("\n");

  const deadSkills = inventory.skills.dead
    .sort((a, b) => b.listingTokens - a.listingTokens)
    .map((s) => `<li><code>${escapeHtml(s.name)}</code> <span>${s.listingTokens} tok</span></li>`)
    .join("\n");

  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>TokenWar Scan</title>
<style>
:root{--bg:#0f1115;--panel:#171a21;--line:#252a34;--fg:#e6e8ec;--dim:#8b93a3;--a:#3fb950;--b:#3fb950;--c:#d29922;--d:#d29922;--e:#f85149;--accent:#58a6ff}
@media(prefers-color-scheme:light){:root{--bg:#f6f8fa;--panel:#fff;--line:#d8dee4;--fg:#1f2328;--dim:#656d76}}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);font:15px/1.6 -apple-system,BlinkMacSystemFont,"Segoe UI",Helvetica,Arial,sans-serif}
.wrap{max-width:1040px;margin:0 auto;padding:48px 24px 80px}
header{border-bottom:1px solid var(--line);padding-bottom:24px;margin-bottom:32px}
h1{margin:0 0 6px;font-size:28px;letter-spacing:-.02em}
.meta{color:var(--dim);font-size:14px}
.overall{display:flex;align-items:center;gap:16px;margin:28px 0}
.overall .big{font-size:56px;font-weight:700;line-height:1}
.cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(230px,1fr));gap:14px;margin-bottom:36px}
.card{background:var(--panel);border:1px solid var(--line);border-radius:10px;padding:16px;display:flex;gap:14px}
.grade{font-size:26px;font-weight:700;width:42px;height:42px;display:flex;align-items:center;justify-content:center;border-radius:8px;flex:none}
.gA,.gB{background:rgba(63,185,80,.15);color:var(--a)}
.gC,.gD{background:rgba(210,153,34,.15);color:var(--c)}
.gE{background:rgba(248,81,73,.15);color:var(--e)}
.card-body{min-width:0}
.card h3{margin:0 0 8px;font-size:14px;font-weight:600}
.card p{margin:8px 0 0;color:var(--dim);font-size:13px}
.meter{background:var(--line);border-radius:99px;height:6px;overflow:hidden}
.meter span{display:block;height:100%;background:var(--accent);border-radius:99px}
h2{font-size:18px;margin:36px 0 14px;letter-spacing:-.01em}
.panel{background:var(--panel);border:1px solid var(--line);border-radius:10px;padding:20px}
table{width:100%;border-collapse:collapse;font-size:14px}
th{text-align:left;color:var(--dim);font-weight:500;font-size:12px;text-transform:uppercase;letter-spacing:.04em;padding:0 10px 10px;border-bottom:1px solid var(--line)}
td{padding:14px 10px;border-bottom:1px solid var(--line);vertical-align:top}
tr:last-child td{border-bottom:none}
.num{text-align:right;font-variant-numeric:tabular-nums;white-space:nowrap}
.cost-compare{display:grid;grid-template-columns:1fr 1fr;gap:14px}
.cost-box{background:var(--panel);border:1px solid var(--line);border-radius:10px;padding:18px}
.cost-box .label{color:var(--dim);font-size:12px;text-transform:uppercase;letter-spacing:.04em}
.cost-box .value{font-size:26px;font-weight:700;margin:6px 0}
.cost-box.real{border-color:var(--a)}
.cost-box.real .value{color:var(--a)}
.note{background:rgba(210,153,34,.08);border-left:3px solid var(--c);padding:14px 16px;border-radius:0 8px 8px 0;margin:16px 0;font-size:14px}
.verdict{font-size:11px;font-weight:700;letter-spacing:.04em;padding:4px 8px;border-radius:5px;white-space:nowrap}
.v-recommend .verdict{background:rgba(63,185,80,.15);color:var(--a)}
.v-keep .verdict{background:rgba(88,166,255,.15);color:var(--accent)}
.v-not-yet .verdict{background:var(--line);color:var(--dim)}
.v-avoid .verdict{background:rgba(248,81,73,.15);color:var(--e)}
.tool{font-weight:600}
.lane{color:var(--dim);font-weight:400;font-size:12px;margin-top:2px}
.detail div{margin-bottom:5px;font-size:13px}
.detail strong{color:var(--dim);font-weight:500;display:inline-block;min-width:78px}
.warn{color:var(--c)}
.mode{font-weight:600;text-transform:capitalize}
.why{color:var(--dim);font-size:13px}
ul.dead{list-style:none;padding:0;margin:0;columns:2;column-gap:24px}
ul.dead li{display:flex;justify-content:space-between;gap:12px;padding:5px 0;font-size:13px;break-inside:avoid}
ul.dead code{font-size:12px}
ul.dead span{color:var(--dim);font-variant-numeric:tabular-nums}
footer{margin-top:48px;padding-top:20px;border-top:1px solid var(--line);color:var(--dim);font-size:13px}
a{color:var(--accent)}
@media(max-width:720px){.cost-compare{grid-template-columns:1fr}ul.dead{columns:1}}
</style>
</head>
<body>
<div class="wrap">
<header>
  <h1>TokenWar Scan</h1>
  <div class="meta">${meta.sessions} sessions · ${meta.turns.toLocaleString()} turns · ${escapeHtml(meta.window)} · ${escapeHtml(meta.model)}</div>
</header>

<div class="overall">
  <div class="grade g${gradeOf(scores.overall)} big" style="width:auto;height:auto;padding:14px 22px">${gradeOf(scores.overall)}</div>
  <div><div style="font-size:20px;font-weight:600">${scores.overall}/100</div>
  <div class="meta">Context and cache hygiene across the scanned window</div></div>
</div>

<div class="cards">${scoreCards}</div>

<h2>Dead weight</h2>
<div class="panel">
  <p style="margin-top:0"><strong>${inventory.skills.dead.length}</strong> of ${inventory.skills.all.length} installed skills were never invoked, adding
  <strong>${formatTokens(inventory.skills.deadListingTokens)} tokens</strong> to every request.
  ${inventory.mcp.dead.length ? `<strong>${inventory.mcp.dead.length}</strong> MCP servers were never called: ${inventory.mcp.dead.map((s) => `<code>${escapeHtml(s.name)}</code>`).join(", ")}.` : ""}</p>
  <ul class="dead">${deadSkills}</ul>
</div>

<h2>What that actually costs</h2>
<div class="cost-compare">
  <div class="cost-box">
    <div class="label">Naive — input re-sent each turn</div>
    <div class="value">${formatDollars(prefixCost.naiveDollars)}</div>
    <div class="meta">${formatTokens(prefixCost.naiveTokens)} tokens</div>
  </div>
  <div class="cost-box real">
    <div class="label">Real — the prefix is cached</div>
    <div class="value">${formatDollars(prefixCost.cachedDollars)}</div>
    <div class="meta">${formatTokens(prefixCost.equivalentTokens)} token-equivalents</div>
  </div>
</div>
<div class="note">
  The naive figure overstates cost by <strong>${prefixCost.overstatementFactor.toFixed(1)}x</strong>. A static block sits in the prompt prefix, so it is billed as a cache read at 0.1x, not as fresh input.
  Caching already absorbs ${formatPercent(1 - prefixCost.cachedDollars / Math.max(prefixCost.naiveDollars, 1e-9))} of that theoretical waste.
</div>
<div class="note">
  <strong>But caching discounts price, not space.</strong> Those ${formatTokens(occupancy.blockTokens)} tokens still occupy
  <strong>${formatPercent(occupancy.windowShare)}</strong> of the ${formatTokens(occupancy.contextWindow)} context window on every request
  — ${formatPercent(occupancy.firstRequestShare)} of a median first request — bringing compaction forward.
  And ${formatPercent(cacheStats.cacheWriteTurns / Math.max(1, cacheStats.turns))} of turns already rebuild the prefix
  (mean ${formatTokens(cacheStats.meanRewrite)} tokens, ${formatDollars(cacheStats.rewriteDollars)} total): every capability added or removed forces that rebuild at 1.25x instead of a 0.1x read.
</div>

<h2>Workload profile</h2>
<div class="panel">
<table>
  <thead><tr><th>Mode</th><th>Confidence</th><th class="num"></th><th>Evidence</th></tr></thead>
  <tbody>${profileRows}</tbody>
</table>
<p class="meta" style="margin-bottom:0">Not inferrable from coding-agent logs: SEO, product, design. Their work happens in tools these logs never observe, and absence of signal is not signal.</p>
</div>

<h2>Recommendations</h2>
<div class="panel">
<table>
  <thead><tr><th>Verdict</th><th>Tool</th><th>Evidence</th><th class="num">Lane value</th></tr></thead>
  <tbody>${recRows}</tbody>
</table>
</div>
${
  overlaps.length
    ? `<div class="note"><strong>Overlapping lanes.</strong> ${overlaps
        .map((o) => `${escapeHtml(o.a)} + ${escapeHtml(o.b)} (${escapeHtml(o.lanes.join(", "))})`)
        .join("; ")}. These act on the same bytes — do not add their savings together.</div>`
    : ""
}

<footer>
  Every token figure comes from provider-reported usage fields, not estimates. Lane values are bounded by the payload each tool can act on.<br>
  TokenWar recommends tools maintained by its own authors; the arithmetic above is shown so each recommendation can be checked.<br>
  Report shape inspired by <a href="https://github.com/gmetais/YellowLabTools">Yellow Lab Tools</a> by Gaël Métais.
</footer>
</div>
</body>
</html>`;
}
