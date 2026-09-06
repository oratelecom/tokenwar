// tokenwar scan — local agent-log audit.
//
// Reads agent session logs, measures what is loaded into every request against
// what was actually used, and reports the cost honestly: cache-adjusted price,
// plus the context-window occupancy that caching does not discount.

import { execFileSync } from "node:child_process";
import { writeFileSync, existsSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";

import { listSessionFiles, parseSessionFile, aggregateSessions, median, expandHome } from "./lib/parse.mjs";
import { pricingFor, observedCost, uncachedCost, prefixBlockCost, windowOccupancy, invalidationCost, dollars, CACHE_WRITE_5M_MULTIPLIER } from "./lib/economics.mjs";
import { collectSkills, collectMcpServers, crossReference } from "./lib/inventory.mjs";
import { inferProfile } from "./lib/profile.mjs";
import { adapterFor } from "./lib/adapters.mjs";
import { buildRecommendations, BUNDLES } from "./lib/recommend.mjs";
import { renderTerminal, renderHtml, computeScores } from "./lib/report.mjs";

// Each client stores sessions somewhere different and in a different shape.
// `pattern` selects that client's session files; `usage` records whether the
// format carries token telemetry, so a client without it is never priced.
const CLIENTS = [
  {
    id: "claude",
    name: "Claude Code",
    roots: ["~/.claude/projects"],
    env: "TOKENWAR_CLAUDE_LOG_ROOT",
    pattern: /\.jsonl$/,
    usage: true,
  },
  {
    id: "codex",
    name: "Codex",
    roots: ["~/.codex/sessions"],
    env: "TOKENWAR_CODEX_LOG_ROOT",
    pattern: /rollout-.*\.jsonl$/,
    usage: true,
  },
  {
    id: "gemini",
    name: "Gemini CLI",
    roots: ["~/.gemini/tmp"],
    env: "TOKENWAR_GEMINI_LOG_ROOT",
    pattern: /logs\.json$/,
    usage: false,
  },
  {
    id: "copilot",
    name: "GitHub Copilot CLI",
    roots: ["~/.copilot/history-session-state", "~/.copilot/session-state", "~/.copilot"],
    env: "TOKENWAR_COPILOT_LOG_ROOT",
    pattern: /\.jsonl$/,
    usage: true,
  },
  {
    id: "opencode",
    name: "opencode",
    roots: ["~/.local/share/opencode/storage", "~/.local/share/opencode"],
    env: "TOKENWAR_OPENCODE_LOG_ROOT",
    pattern: /\.jsonl$/,
    usage: true,
  },
];

const DEFAULT_DAYS = 30;
const DEFAULT_MAX_SESSIONS = 400;

function usage() {
  console.log(`tokenwar scan — audit what your agent loads versus what it uses

Usage:
  tokenwar scan                     audit the last ${DEFAULT_DAYS} days
  tokenwar scan --days N            change the window
  tokenwar scan --json              machine-readable output
  tokenwar scan --html [PATH]       write an HTML report (default: ./tokenwar-scan.html)
  tokenwar scan --open              write the HTML report and open it
  tokenwar scan --client ID         restrict to one client (${CLIENTS.map((c) => c.id).join(", ")})
  tokenwar scan --model NAME        price against a model (claude-opus, claude-sonnet, claude-haiku)

Environment:
  TOKENWAR_<CLIENT>_LOG_ROOT=/path  override a client's log location`);
}

function parseArgs(argv) {
  const args = {
    days: DEFAULT_DAYS,
    json: false,
    html: null,
    open: false,
    clients: [],
    model: null,
    maxSessions: DEFAULT_MAX_SESSIONS,
  };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "-h" || arg === "--help") {
      usage();
      process.exit(0);
    } else if (arg === "--json") {
      args.json = true;
    } else if (arg === "--open") {
      args.open = true;
      if (!args.html) args.html = "tokenwar-scan.html";
    } else if (arg === "--html") {
      const next = argv[i + 1];
      if (next && !next.startsWith("--")) {
        args.html = next;
        i += 1;
      } else {
        args.html = "tokenwar-scan.html";
      }
    } else if (arg === "--days") {
      args.days = Number(argv[i + 1]);
      i += 1;
      if (!Number.isFinite(args.days) || args.days < 1) throw new Error("--days must be a positive number");
    } else if (arg === "--max-sessions") {
      args.maxSessions = Number(argv[i + 1]);
      i += 1;
    } else if (arg === "--client") {
      args.clients.push(argv[i + 1]);
      i += 1;
    } else if (arg === "--model") {
      args.model = argv[i + 1];
      i += 1;
    } else {
      throw new Error(`unknown argument: ${arg}`);
    }
  }
  return args;
}

// Tool states come from status.sh when it is available; a missing status file
// only means states show as unknown, never that the scan fails.
function loadToolStates() {
  const script = process.env.TOKENWAR_STATUS_SCRIPT || join(new URL(".", import.meta.url).pathname, "status.sh");
  if (!existsSync(script)) return {};
  try {
    const out = execFileSync("bash", [script, "--json"], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] });
    const parsed = JSON.parse(out);
    const states = {};
    for (const [id, value] of Object.entries(parsed.tools || {})) states[id] = value.state;
    return states;
  } catch {
    return {};
  }
}

// MCP servers are only enumerable from a live session, so the scan reads the
// counts the caller recorded rather than pretending to discover them.
function loadKnownMcpCounts() {
  const raw = process.env.TOKENWAR_MCP_TOOL_COUNTS;
  if (!raw) return {};
  try {
    return JSON.parse(raw);
  } catch {
    return {};
  }
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  const since = Date.now() - args.days * 86400000;

  const selected = args.clients.length
    ? CLIENTS.filter((client) => args.clients.includes(client.id))
    : CLIENTS;

  const sessions = [];
  const perClient = [];
  for (const client of selected) {
    // An explicit override replaces the built-in roots entirely.
    const roots = process.env[client.env]
      ? [expandHome(process.env[client.env])]
      : client.roots.map(expandHome);

    const present = roots.filter((root) => existsSync(root));
    if (present.length === 0) {
      perClient.push({ id: client.id, name: client.name, status: "not-installed", files: 0, sessions: 0 });
      continue;
    }

    // Only the first root that yields files is used, so a fallback root does
    // not double-count sessions already found in the preferred one.
    let files = [];
    let usedRoot = present[0];
    for (const root of present) {
      const found = listSessionFiles(root, { maxFiles: args.maxSessions, since, pattern: client.pattern });
      if (found.length > 0) {
        files = found;
        usedRoot = root;
        break;
      }
    }

    const adapter = adapterFor(client.id);
    let parsed = 0;
    for (const file of files) {
      const session = adapter ? adapter.parse(file.path) : parseSessionFile(file.path);
      if (session) {
        session.client = session.client || client.id;
        sessions.push(session);
        parsed += 1;
      }
    }

    // Distinguish "no logs" from "logs we cannot read": an unparsed client must
    // never look like an efficient one.
    let status = "ok";
    if (files.length === 0) status = "no-logs";
    else if (parsed === 0) status = "unparsed";

    perClient.push({
      id: client.id,
      name: client.name,
      root: usedRoot,
      files: files.length,
      sessions: parsed,
      status,
      usage: client.usage,
    });
  }

  if (sessions.length === 0) {
    console.error(`tokenwar scan: no agent sessions found in the last ${args.days} days.`);
    console.error(`Looked in: ${selected.map((c) => c.root).join(", ")}`);
    process.exit(1);
  }

  const aggregate = aggregateSessions(sessions);

  // Price against the model that did most of the work, not whichever session
  // happens to sort first: a short Haiku subagent transcript would otherwise
  // price an Opus workload at a fifteenth of its real cost.
  let dominantModel = null;
  if (!args.model) {
    const byModel = new Map();
    for (const session of sessions) {
      if (!session.model) continue;
      const volume = session.freshInput + session.cacheCreate + session.cacheRead + session.output;
      byModel.set(session.model, (byModel.get(session.model) || 0) + volume);
    }
    dominantModel = [...byModel.entries()].sort((left, right) => right[1] - left[1])[0]?.[0] || null;
  }
  const price = pricingFor(args.model || dominantModel);

  // Inventory: what is loaded on every request, and what was invoked.
  const skills = collectSkills();
  const mcpServers = collectMcpServers({ knownToolCounts: loadKnownMcpCounts() });
  const inventory = crossReference({
    skills,
    mcpServers,
    skillsInvoked: aggregate.skillsInvoked,
    mcpCalls: aggregate.mcpCalls,
  });

  // Cost of the dead listing, both ways round.
  const avgTurns = Math.max(1, Math.round(aggregate.turns / aggregate.sessions));
  const meanRewrite = aggregate.cacheWriteTurns > 0
    ? Math.round(aggregate.cacheWriteTokensAfterFirst / aggregate.cacheWriteTurns)
    : 0;

  // Skills are a Claude Code capability, so the listing is only presented on
  // Claude turns. Pricing it against every client's turns would attribute the
  // cost to sessions that never carried it.
  const skillBearingSessions = sessions.filter((session) => (session.client || "claude") === "claude");
  const skillBearingTurns = skillBearingSessions.reduce((sum, session) => sum + session.turns, 0);

  const prefixCost = prefixBlockCost({
    blockTokens: inventory.skills.deadListingTokens,
    turns: skillBearingTurns,
    price,
    // The static skill listing is re-sent on a cold prefix, not on every turn
    // that appends to the conversation. One write per session is the honest
    // floor; TTL expiry during idle gaps can add more, which we cannot see.
    cacheWriteTurns: Math.max(1, skillBearingSessions.length),
  });

  const medianFirst = median(aggregate.firstRequestTokens);
  const occupancy = windowOccupancy({
    blockTokens: inventory.skills.deadListingTokens,
    contextWindow: price.contextWindow,
    firstRequestTokens: medianFirst,
  });

  const presented = aggregate.freshInput + aggregate.cacheCreate + aggregate.cacheRead;
  // Cost of one inventory change: the whole prefix up to that point is rewritten
  // at 1.25x instead of read at 0.1x. Priced at a typical mid-session size.
  const typicalPrefix = median(aggregate.peakInputTokens) / 2;
  const invalidation = invalidationCost({ prefixTokens: typicalPrefix, price });

  const cacheStats = {
    turns: aggregate.turns,
    presented,
    cacheRead: aggregate.cacheRead,
    cacheCreate: aggregate.cacheCreate,
    cacheWriteTurns: aggregate.cacheWriteTurns,
    meanRewrite,
    rewriteDollars: dollars(aggregate.cacheWriteTokensAfterFirst, price.input * CACHE_WRITE_5M_MULTIPLIER),
    invalidationPenalty: invalidation.penalty,
    typicalPrefixTokens: Math.round(typicalPrefix),
  };

  const profile = inferProfile(aggregate);
  const { items: recommendations, overlaps } = buildRecommendations({
    aggregate,
    price,
    profile,
    toolStates: loadToolStates(),
    avgTurns,
  });

  const scores = computeScores({ inventory, occupancy, cacheStats });

  const report = {
    meta: {
      sessions: aggregate.sessions,
      turns: aggregate.turns,
      window: `${args.days}d`,
      model: price.id,
      clients: perClient,
      generatedAt: new Date().toISOString(),
    },
    scores,
    inventory,
    occupancy,
    cacheStats,
    prefixCost,
    profile,
    recommendations,
    overlaps,
    spend: {
      observed: observedCost(aggregate, price),
      uncached: uncachedCost(aggregate, price),
    },
    bundles: BUNDLES,
  };

  if (args.json) {
    // Maps do not survive JSON.stringify, so project the ones a consumer needs.
    console.log(
      JSON.stringify(
        {
          ...report,
          inventory: {
            skills: {
              total: inventory.skills.all.length,
              dead: inventory.skills.dead.map((s) => ({ name: s.name, source: s.source, listingTokens: s.listingTokens })),
              used: inventory.skills.used.map((s) => ({ name: s.name, invocations: s.invocations })),
              listingTokens: inventory.skills.listingTokens,
              deadListingTokens: inventory.skills.deadListingTokens,
            },
            mcp: inventory.mcp,
          },
          profile: {
            primary: profile.primary,
            determinate: profile.determinate,
            distribution: profile.distribution.map((d) => ({ mode: d.mode, confidence: d.confidence, evidence: d.evidence.map((e) => e.why) })),
            notInferrable: profile.notInferrable,
          },
        },
        null,
        2
      )
    );
    return;
  }

  if (args.html) {
    const path = args.html.startsWith("/") ? args.html : join(process.cwd(), args.html);
    writeFileSync(path, renderHtml(report), "utf8");
    console.log(renderTerminal(report));
    console.log(`  HTML report written to ${path}`);
    if (args.open) {
      try {
        execFileSync(process.platform === "darwin" ? "open" : "xdg-open", [path], { stdio: "ignore" });
      } catch {
        // Opening a browser is a convenience; failing to do so is not an error.
      }
    }
    return;
  }

  console.log(renderTerminal(report));
}

try {
  main();
} catch (error) {
  console.error(`tokenwar scan: ${error.message}`);
  process.exit(2);
}
