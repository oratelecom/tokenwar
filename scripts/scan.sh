#!/usr/bin/env bash
# tokenwar scan — local log opportunity estimator.
#
# This is not native telemetry. It reads local agent logs and estimates where
# TokenWar tools could have reduced input/output pressure. Real savings remain
# owned by `tokenwar gain`.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

readonly DEFAULT_MAX_FILES=200
readonly DEFAULT_MAX_BYTES_PER_FILE=524288
readonly DEFAULT_MIN_RECOMMENDATION_TOKENS=1000
readonly TOKEN_CHARS_PER_TOKEN=4
readonly STATUS_SCRIPT="${SCRIPT_DIR}/status.sh"

TOKENWAR_SCAN_MAX_FILES="${TOKENWAR_SCAN_MAX_FILES:-$DEFAULT_MAX_FILES}" \
TOKENWAR_SCAN_MAX_BYTES_PER_FILE="${TOKENWAR_SCAN_MAX_BYTES_PER_FILE:-$DEFAULT_MAX_BYTES_PER_FILE}" \
TOKENWAR_SCAN_MIN_RECOMMENDATION_TOKENS="${TOKENWAR_SCAN_MIN_RECOMMENDATION_TOKENS:-$DEFAULT_MIN_RECOMMENDATION_TOKENS}" \
TOKENWAR_SCAN_CHARS_PER_TOKEN="$TOKEN_CHARS_PER_TOKEN" \
TOKENWAR_STATUS_SCRIPT="$STATUS_SCRIPT" \
node --input-type=module - "$@" <<'NODE'
import { execFileSync, spawnSync } from "node:child_process";
import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";

const CLIENTS = [
  {
    id: "claude",
    name: "Claude Code",
    cli: "claude",
    roots: ["TOKENWAR_CLAUDE_LOG_ROOT", "~/.claude"],
  },
  {
    id: "codex",
    name: "Codex",
    cli: "codex",
    roots: ["TOKENWAR_CODEX_LOG_ROOT", "~/.codex"],
  },
  {
    id: "gemini",
    name: "Gemini CLI",
    cli: "gemini",
    roots: ["TOKENWAR_GEMINI_LOG_ROOT", "~/.gemini"],
  },
  {
    id: "kimi",
    name: "Kimi Code CLI",
    cli: "kimi",
    roots: ["TOKENWAR_KIMI_LOG_ROOT", "~/.kimi-code"],
  },
  {
    id: "opencode",
    name: "opencode",
    cli: "opencode",
    roots: ["TOKENWAR_OPENCODE_LOG_ROOT", "~/.local/share/opencode", "~/.config/opencode"],
  },
  {
    id: "vibe",
    name: "Vibe/Ora agents",
    cli: "",
    roots: ["TOKENWAR_VIBE_LOG_ROOT", "~/.ora/tasks", "~/.ora/contribute", "~/.claude/contributebg/logs"],
  },
  {
    id: "cursor",
    name: "Cursor",
    cli: "cursor",
    roots: ["TOKENWAR_CURSOR_LOG_ROOT", "~/.cursor"],
  },
];

const LOG_EXTENSIONS = new Set([".jsonl", ".log", ".txt", ".md"]);
const MAX_DEPTH = 5;
const RTK_COMMAND_TOKEN_BUDGET = 900;
const REPO_DISCOVERY_TOKEN_BUDGET = 700;
const HEAVY_PAYLOAD_TOKEN_BUDGET = 1500;
const MEMORY_TOKEN_BUDGET = 800;
const CODE_GENERATION_TOKEN_BUDGET = 500;
const PXPIPE_PAYLOAD_TOKEN_RATIO = 0.15;
const CAVEMAN_OUTPUT_TOKEN_RATIO = 0.12;
const TOTAL_TOKEN_RATIO_RTK_CAP = 0.45;
const TOTAL_TOKEN_RATIO_REPO_CAP = 0.30;
const TOTAL_TOKEN_RATIO_HEAVY_CAP = 0.35;
const TOTAL_TOKEN_RATIO_MEMORY_CAP = 0.20;
const TOTAL_TOKEN_RATIO_CODE_CAP = 0.10;
const LONG_LINE_LENGTH = 2000;
const LARGE_PAYLOAD_TOKENS = 50000;
const DECISION_ENABLE = "ENABLE";
const DECISION_KEEP = "KEEP";
const DECISION_SKIP = "TOO MUCH";
const DECISION_TRY = "TRY";

const PATTERNS = {
  shell: /\b(Bash|exec|shell|command|tool call|run command)\b/i,
  command: /\b(git|gh|rg|grep|find|fd|sed|cat|head|tail|nl|awk|jq|curl|wget|docker|npm|pnpm|yarn|go|cargo|pytest|phpunit|composer|make|just|bats)\b/i,
  search: /\b(rg|grep|find|fd|git grep|search_query)\b/i,
  read: /\b(cat|sed -n|head|tail|nl -ba|readFile|Read tool|open\(|view file)\b/i,
  http: /\b(curl|wget|gh api|gh pr view|web\.run|search_query|open\(|fetch|scrap|scrape|crawl)\b/i,
  diff: /\b(git diff|gh pr diff|apply_patch|diff --git)\b/i,
  test: /\b(go test|pytest|phpunit|bats|cargo test|npm test|pnpm test|yarn test|make test|shellcheck)\b/i,
  memory: /\b(resume|previous session|context|summary|compaction|AGENTS\.md|coding-rules|SKILL\.md|neverdothis|where we were|red.?green)\b/i,
  codeWrite: /\b(apply_patch|writeFile|cat >|tee .*<<|git commit|added [0-9]+ files?|insertions?\(|create mode)\b/i,
  prose: /\b(assistant|codex|claude|summary|final answer|commentary|review|explain|analysis|resume)\b/i,
};

function usage() {
  console.log(`tokenwar scan — local log opportunity estimator

Usage:
  tokenwar scan [--client ID ...] [--clients a,b] [--all] [--json]

Clients:
  ${CLIENTS.map((client) => client.id).join(", ")}

Environment:
  TOKENWAR_SCAN_MAX_FILES=${process.env.TOKENWAR_SCAN_MAX_FILES}
  TOKENWAR_SCAN_MAX_BYTES_PER_FILE=${process.env.TOKENWAR_SCAN_MAX_BYTES_PER_FILE}
  TOKENWAR_SCAN_MIN_RECOMMENDATION_TOKENS=${process.env.TOKENWAR_SCAN_MIN_RECOMMENDATION_TOKENS}
  TOKENWAR_<CLIENT>_LOG_ROOT=/custom/path`);
}

function parseArgs(argv) {
  const selected = new Set();
  let all = false;
  let json = false;
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--help" || arg === "-h") {
      usage();
      process.exit(0);
    }
    if (arg === "--all") {
      all = true;
      continue;
    }
    if (arg === "--json") {
      json = true;
      continue;
    }
    if (arg === "--client") {
      const value = argv[i + 1];
      if (!value) throw new Error("--client requires a value");
      selected.add(value);
      i += 1;
      continue;
    }
    if (arg === "--clients") {
      const value = argv[i + 1];
      if (!value) throw new Error("--clients requires a value");
      for (const id of value.split(",")) {
        if (id.trim()) selected.add(id.trim());
      }
      i += 1;
      continue;
    }
    throw new Error(`unknown arg: ${arg}`);
  }
  return { all, json, selected };
}

function expandHome(path) {
  return path.startsWith("~/") ? join(homedir(), path.slice(2)) : path;
}

function rootPaths(client) {
  const roots = [];
  for (const item of client.roots) {
    if (item.startsWith("TOKENWAR_")) {
      const value = process.env[item];
      if (value) roots.push(value);
      continue;
    }
    roots.push(expandHome(item));
  }
  return [...new Set(roots)];
}

function hasCommand(command) {
  if (!command) return false;
  return spawnSync("sh", ["-lc", `command -v ${command}`], { stdio: "ignore" }).status === 0;
}

function fileExtension(path) {
  const index = path.lastIndexOf(".");
  return index === -1 ? "" : path.slice(index).toLowerCase();
}

function listLogFiles(root, maxFiles) {
  if (!existsSync(root)) return [];
  const files = [];
  const stack = [{ path: root, depth: 0 }];
  while (stack.length > 0 && files.length < maxFiles) {
    const current = stack.pop();
    let entries;
    try {
      entries = readdirSync(current.path, { withFileTypes: true });
    } catch {
      continue;
    }
    for (const entry of entries) {
      const path = join(current.path, entry.name);
      if (entry.isDirectory()) {
        if (current.depth < MAX_DEPTH && !entry.name.startsWith("node_modules")) {
          stack.push({ path, depth: current.depth + 1 });
        }
        continue;
      }
      if (!entry.isFile()) continue;
      if (LOG_EXTENSIONS.has(fileExtension(entry.name))) files.push(path);
      if (files.length >= maxFiles) break;
    }
  }
  return files.sort((left, right) => {
    try {
      return statSync(right).mtimeMs - statSync(left).mtimeMs;
    } catch {
      return 0;
    }
  }).slice(0, maxFiles);
}

function readBounded(path, maxBytes) {
  const data = readFileSync(path);
  return data.length > maxBytes ? data.subarray(data.length - maxBytes).toString("utf8") : data.toString("utf8");
}

function emptyMetrics(client, roots, installed) {
  return {
    id: client.id,
    name: client.name,
    installed,
    roots,
    files: 0,
    bytes: 0,
    lines: 0,
    estimated_tokens_seen: 0,
    shell_hits: 0,
    command_hits: 0,
    search_hits: 0,
    read_hits: 0,
    http_hits: 0,
    diff_hits: 0,
    test_hits: 0,
    memory_hits: 0,
    code_write_hits: 0,
    prose_hits: 0,
    long_lines: 0,
  };
}

function scanClient(client, maxFiles, maxBytesPerFile) {
  const roots = rootPaths(client);
  const installed = hasCommand(client.cli) || roots.some((root) => existsSync(root));
  const metrics = emptyMetrics(client, roots.filter((root) => existsSync(root)), installed);
  for (const root of roots) {
    const files = listLogFiles(root, Math.max(0, maxFiles - metrics.files));
    for (const file of files) {
      let text;
      try {
        text = readBounded(file, maxBytesPerFile);
      } catch {
        continue;
      }
      metrics.files += 1;
      metrics.bytes += Buffer.byteLength(text);
      const lines = text.split(/\r?\n/);
      metrics.lines += lines.length;
      for (const line of lines) {
        if (line.length >= LONG_LINE_LENGTH) metrics.long_lines += 1;
        if (PATTERNS.shell.test(line)) metrics.shell_hits += 1;
        if (PATTERNS.command.test(line)) metrics.command_hits += 1;
        if (PATTERNS.search.test(line)) metrics.search_hits += 1;
        if (PATTERNS.read.test(line)) metrics.read_hits += 1;
        if (PATTERNS.http.test(line)) metrics.http_hits += 1;
        if (PATTERNS.diff.test(line)) metrics.diff_hits += 1;
        if (PATTERNS.test.test(line)) metrics.test_hits += 1;
        if (PATTERNS.memory.test(line)) metrics.memory_hits += 1;
        if (PATTERNS.codeWrite.test(line)) metrics.code_write_hits += 1;
        if (PATTERNS.prose.test(line)) metrics.prose_hits += 1;
      }
    }
  }
  metrics.estimated_tokens_seen = Math.ceil(metrics.bytes / Number(process.env.TOKENWAR_SCAN_CHARS_PER_TOKEN || "4"));
  return metrics;
}

function estimate(capTokens, count, perHit) {
  return Math.max(0, Math.round(Math.min(capTokens, count * perHit)));
}

function humanTokens(tokens) {
  if (tokens >= 1000000) return `${(tokens / 1000000).toFixed(1)}M`;
  if (tokens >= 1000) return `${(tokens / 1000).toFixed(1)}K`;
  return String(tokens);
}

function loadStatus() {
  if (process.env.TOKENWAR_SCAN_SKIP_STATUS === "1") return {};
  try {
    const out = execFileSync("bash", [process.env.TOKENWAR_STATUS_SCRIPT, "--json"], { encoding: "utf8" });
    return JSON.parse(out);
  } catch (error) {
    const stdout = error?.stdout?.toString();
    if (stdout) {
      try {
        return JSON.parse(stdout);
      } catch {
        return {};
      }
    }
    return {};
  }
}

function toolState(status, id) {
  return status?.tools?.[id]?.state || "unknown";
}

function decisionFor(item) {
  const minRecommendationTokens = Number(process.env.TOKENWAR_SCAN_MIN_RECOMMENDATION_TOKENS);
  if (item.estimated_tokens < minRecommendationTokens) return DECISION_SKIP;
  if (item.tool === "context-mode alternative") return DECISION_TRY;
  if (item.tool === "Probe / Stacklit / Serena / Graphify") return DECISION_TRY;
  if (item.state === "OK") return DECISION_KEEP;
  if (item.state === "installed-disabled") return DECISION_ENABLE;
  if (item.state === "not-installed" || item.state === "unknown") return DECISION_TRY;
  return DECISION_TRY;
}

function buildRecommendations(metricsList, status) {
  const aggregate = metricsList.reduce((acc, item) => {
    for (const key of Object.keys(acc)) acc[key] += item[key] || 0;
    return acc;
  }, {
    estimated_tokens_seen: 0,
    command_hits: 0,
    search_hits: 0,
    read_hits: 0,
    http_hits: 0,
    diff_hits: 0,
    test_hits: 0,
    memory_hits: 0,
    code_write_hits: 0,
    prose_hits: 0,
    long_lines: 0,
  });

  const total = aggregate.estimated_tokens_seen;
  const repoDiscoveryHits = aggregate.search_hits + aggregate.read_hits + aggregate.diff_hits;
  const heavyPayloadHits = aggregate.http_hits + aggregate.long_lines;
  const shellHits = aggregate.command_hits + aggregate.test_hits;
  const recommendations = [
    {
      tool: "RTK",
      state: toolState(status, "rtk"),
      estimated_tokens: estimate(total * TOTAL_TOKEN_RATIO_RTK_CAP, shellHits, RTK_COMMAND_TOKEN_BUDGET),
      signal: `${shellHits} shell/test command signals`,
      action: "Keep RTK enabled; route noisy shell discovery through Bash or direct rtk commands.",
    },
    {
      tool: "Probe / Stacklit / Serena / Graphify",
      state: "candidate",
      estimated_tokens: estimate(total * TOTAL_TOKEN_RATIO_REPO_CAP, repoDiscoveryHits, REPO_DISCOVERY_TOKEN_BUDGET),
      signal: `${repoDiscoveryHits} repo discovery signals`,
      action: "Use a repo-map/code-context layer before broad rg/find/sed sweeps.",
    },
    {
      tool: "context-mode alternative",
      state: toolState(status, "context-mode"),
      estimated_tokens: estimate(total * TOTAL_TOKEN_RATIO_HEAVY_CAP, heavyPayloadHits, HEAVY_PAYLOAD_TOKEN_BUDGET),
      signal: `${heavyPayloadHits} heavy payload or scrape signals`,
      action: "Prefer Probe/Stacklit for code; reserve context-mode or context-link for sandboxed heavy data.",
    },
    {
      tool: "claude-mem / OpenWiki",
      state: toolState(status, "claude-mem"),
      estimated_tokens: estimate(total * TOTAL_TOKEN_RATIO_MEMORY_CAP, aggregate.memory_hits, MEMORY_TOKEN_BUDGET),
      signal: `${aggregate.memory_hits} repeated memory/context signals`,
      action: "Persist project decisions and generated wiki pages so resumes read compact memory, not old logs.",
    },
    {
      tool: "pxpipe",
      state: toolState(status, "pxpipe"),
      estimated_tokens: total >= LARGE_PAYLOAD_TOKENS ? Math.round(total * PXPIPE_PAYLOAD_TOKEN_RATIO) : estimate(total * PXPIPE_PAYLOAD_TOKEN_RATIO, aggregate.long_lines, HEAVY_PAYLOAD_TOKEN_BUDGET),
      signal: `${humanTokens(total)} scanned log tokens, ${aggregate.long_lines} long-line payloads`,
      action: "Use proxy-side payload compression when provider traffic contains large repeated text blocks.",
    },
    {
      tool: "caveman",
      state: toolState(status, "caveman"),
      estimated_tokens: Math.round(total * CAVEMAN_OUTPUT_TOKEN_RATIO),
      signal: `${aggregate.prose_hits} prose/review/summary signals`,
      action: "Use terse response mode for status, reviews, and repetitive operational chatter.",
    },
    {
      tool: "ponytail",
      state: toolState(status, "ponytail"),
      estimated_tokens: estimate(total * TOTAL_TOKEN_RATIO_CODE_CAP, aggregate.code_write_hits, CODE_GENERATION_TOKEN_BUDGET),
      signal: `${aggregate.code_write_hits} code-generation or diff signals`,
      action: "Use ponytail for vibe-coding and refactors; smaller code compounds on every future read.",
    },
  ];

  const minRecommendationTokens = Number(process.env.TOKENWAR_SCAN_MIN_RECOMMENDATION_TOKENS);
  if (!Number.isInteger(minRecommendationTokens) || minRecommendationTokens < 0) {
    throw new Error("TOKENWAR_SCAN_MIN_RECOMMENDATION_TOKENS must be a non-negative integer");
  }

  return recommendations
    .map((item) => ({ ...item, decision: decisionFor(item) }))
    .sort((left, right) => right.estimated_tokens - left.estimated_tokens);
}

function printText(metricsList, recommendations) {
  const toolColumnWidth = 42;
  console.log("# /tokenwar scan");
  console.log("");
  console.log("Local log scan. Numbers below are estimated opportunity, not native savings.");
  console.log("");
  console.log("  client        files    scanned     est tokens   top signals");
  console.log("  -------------------------------------------------------------");
  for (const item of metricsList) {
    const signals = [
      item.command_hits ? `${item.command_hits} cmd` : "",
      item.search_hits ? `${item.search_hits} search` : "",
      item.read_hits ? `${item.read_hits} read` : "",
      item.http_hits ? `${item.http_hits} web` : "",
      item.code_write_hits ? `${item.code_write_hits} code` : "",
    ].filter(Boolean).join(", ") || "none";
    console.log(`  ${item.id.padEnd(12)}  ${String(item.files).padStart(5)}  ${humanTokens(item.bytes).padStart(9)}  ${humanTokens(item.estimated_tokens_seen).padStart(10)}   ${signals}`);
  }
  console.log("");
  console.log("Recommendations");
  console.log(`  ${"tool".padEnd(toolColumnWidth)} decision   est avoidable   state       why`);
  console.log("  ----------------------------------------------------------------------------------------------------");
  for (const item of recommendations) {
    console.log(`  ${item.tool.padEnd(toolColumnWidth)} ${item.decision.padEnd(9)} ${humanTokens(item.estimated_tokens).padStart(12)}   ${item.state.padEnd(10)} ${item.signal}`);
    console.log(`      ${item.action}`);
  }
}

try {
  const args = parseArgs(process.argv.slice(2));
  const requestedIds = args.selected;
  const unknown = [...requestedIds].filter((id) => !CLIENTS.some((client) => client.id === id));
  if (unknown.length > 0) throw new Error(`unknown client(s): ${unknown.join(", ")}`);

  const maxFiles = Number(process.env.TOKENWAR_SCAN_MAX_FILES);
  const maxBytesPerFile = Number(process.env.TOKENWAR_SCAN_MAX_BYTES_PER_FILE);
  if (!Number.isInteger(maxFiles) || maxFiles < 1) throw new Error("TOKENWAR_SCAN_MAX_FILES must be a positive integer");
  if (!Number.isInteger(maxBytesPerFile) || maxBytesPerFile < 1) throw new Error("TOKENWAR_SCAN_MAX_BYTES_PER_FILE must be a positive integer");

  const candidates = CLIENTS.map((client) => ({ client, roots: rootPaths(client) }));
  let selectedClients;
  if (args.all) {
    selectedClients = CLIENTS;
  } else if (requestedIds.size > 0) {
    selectedClients = CLIENTS.filter((client) => requestedIds.has(client.id));
  } else {
    selectedClients = candidates
      .filter(({ client, roots }) => hasCommand(client.cli) || roots.some((root) => existsSync(root)))
      .map(({ client }) => client);
  }

  const metricsList = selectedClients.map((client) => scanClient(client, maxFiles, maxBytesPerFile));
  const status = loadStatus();
  const recommendations = buildRecommendations(metricsList, status);
  if (args.json) {
    console.log(JSON.stringify({ clients: metricsList, recommendations }, null, 2));
  } else {
    printText(metricsList, recommendations);
  }
} catch (error) {
  console.error(`tokenwar scan: ${error.message}`);
  process.exit(2);
}
NODE
