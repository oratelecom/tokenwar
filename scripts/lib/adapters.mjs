// Per-client log adapters.
//
// Each agent writes a different session format. An adapter normalizes one
// client's log into the same shape the rest of the scan consumes, so token
// figures always come from that client's own telemetry rather than from an
// estimate applied uniformly across clients.
//
// A client with no adapter is reported as "detected, not parseable" rather than
// silently contributing zero, so an empty result is never mistaken for
// efficient usage.

import { readFileSync } from "node:fs";
import { classifyCommand, splitCommands } from "./parse.mjs";

// Shape every adapter returns. Mirrors what parseSessionFile produces.
export function emptyNormalized(path) {
  return {
    path,
    client: null,
    sessionId: null,
    cwd: null,
    model: null,
    turns: 0,
    freshInput: 0,
    cacheCreate: 0,
    cacheRead: 0,
    output: 0,
    cacheWriteTurns: 0,
    cacheWriteTokensAfterFirst: 0,
    cacheReadTurns: 0,
    firstRequestTokens: 0,
    peakInputTokens: 0,
    contextWindow: null,
    compactions: 0,
    toolCalls: new Map(),
    bashFamilies: new Map(),
    bashHeads: new Map(),
    bashCount: 0,
    fileExtensions: new Map(),
    skillsInvoked: new Map(),
    mcpCalls: new Map(),
    lanes: {
      shell: { calls: 0, bytes: 0 },
      search: { calls: 0, bytes: 0 },
      read: { calls: 0, bytes: 0 },
      web: { calls: 0, bytes: 0 },
      test: { calls: 0, bytes: 0 },
      mcp: { calls: 0, bytes: 0 },
      fileRead: { calls: 0, bytes: 0 },
    },
    assistantProseChars: 0,
    codeWrittenChars: 0,
    resultSizes: [],
    sidechainCalls: 0,
    parseErrors: 0,
    lines: 0,
  };
}

function bump(map, key, amount = 1) {
  if (!key) return;
  map.set(key, (map.get(key) || 0) + amount);
}

function laneForFamily(family) {
  if (family === "search") return "search";
  if (family === "read") return "read";
  if (family === "web") return "web";
  if (family === "test") return "test";
  return "shell";
}

// Record a shell command against the families and lane it belongs to. Shared by
// every adapter so command attribution is identical across clients.
function recordShellCommand(session, command) {
  if (!command) return null;
  session.bashCount += 1;
  bump(session.toolCalls, "Bash");
  const commands = splitCommands(command);
  for (const entry of commands) {
    bump(session.bashHeads, entry.head);
    bump(session.bashFamilies, classifyCommand(entry.head));
  }
  return commands.length ? laneForFamily(classifyCommand(commands[0].head)) : "shell";
}

function recordFileWrite(session, filePath, content) {
  if (filePath) {
    const ext = String(filePath).split("/").pop().split(".").pop().toLowerCase();
    if (ext && ext.length <= 6) bump(session.fileExtensions, ext);
  }
  session.codeWrittenChars += String(content || "").length;
}

// --- Codex -----------------------------------------------------------------
//
// Codex writes sessions/YYYY/MM/DD/rollout-*.jsonl. Every line is an envelope
// with a `payload`. Usage arrives as periodic `token_count` payloads carrying a
// cumulative `total_token_usage`, so a turn's cost is the delta between
// successive snapshots rather than the snapshot itself.

const CODEX_SHELL_TOOLS = new Set(["exec_command", "shell", "local_shell", "run_command", "bash"]);
const CODEX_WRITE_TOOLS = new Set(["apply_patch", "write_file", "create_file", "edit_file"]);
const CODEX_READ_TOOLS = new Set(["read_file", "view_file", "cat_file"]);

export function parseCodexSession(path) {
  let raw;
  try {
    raw = readFileSync(path, "utf8");
  } catch {
    return null;
  }

  const session = emptyNormalized(path);
  session.client = "codex";
  const pendingLane = new Map();
  let previousTotals = null;
  let firstTurnSeen = false;

  for (const line of raw.split("\n")) {
    if (!line) continue;
    session.lines += 1;
    let event;
    try {
      event = JSON.parse(line);
    } catch {
      session.parseErrors += 1;
      continue;
    }

    if (event.type === "session_meta") {
      session.sessionId = event.payload?.id || event.payload?.session_id || session.sessionId;
      session.cwd = event.payload?.cwd || session.cwd;
      session.model = event.payload?.model || session.model;
      continue;
    }

    const payload = event.payload;
    if (!payload) continue;

    if (payload.type === "token_count") {
      const info = payload.info;
      if (!info) continue;
      if (info.model_context_window) session.contextWindow = info.model_context_window;

      // total_token_usage is cumulative; difference successive snapshots so a
      // turn is counted once rather than re-counted on every later snapshot.
      const totals = info.total_token_usage;
      if (!totals) continue;
      const previous = previousTotals || { input_tokens: 0, cached_input_tokens: 0, cache_write_input_tokens: 0, output_tokens: 0 };
      const freshDelta = Math.max(0, (totals.input_tokens || 0) - (previous.input_tokens || 0));
      const cachedDelta = Math.max(0, (totals.cached_input_tokens || 0) - (previous.cached_input_tokens || 0));
      const writeDelta = Math.max(0, (totals.cache_write_input_tokens || 0) - (previous.cache_write_input_tokens || 0));
      const outputDelta = Math.max(0, (totals.output_tokens || 0) - (previous.output_tokens || 0));
      previousTotals = totals;

      if (freshDelta === 0 && cachedDelta === 0 && outputDelta === 0 && writeDelta === 0) continue;

      session.turns += 1;
      // Codex reports cached input separately from fresh input; `input_tokens`
      // already includes the cached portion, so subtract it to avoid counting
      // the same tokens as both fresh and cached.
      session.freshInput += Math.max(0, freshDelta - cachedDelta);
      session.cacheRead += cachedDelta;
      session.cacheCreate += writeDelta;
      session.output += outputDelta;

      const presented = freshDelta + writeDelta;
      if (presented > session.peakInputTokens) session.peakInputTokens = presented;
      if (!firstTurnSeen) {
        session.firstRequestTokens = presented;
        firstTurnSeen = true;
      } else if (writeDelta > 0) {
        session.cacheWriteTurns += 1;
        session.cacheWriteTokensAfterFirst += writeDelta;
      }
      if (cachedDelta > 0) session.cacheReadTurns += 1;
      continue;
    }

    if (payload.type === "agent_message" || payload.type === "message") {
      const text = typeof payload.message === "string"
        ? payload.message
        : payload.content?.map?.((part) => part?.text || "").join("") || "";
      session.assistantProseChars += text.length;
      continue;
    }

    if (payload.type === "function_call" || payload.type === "custom_tool_call") {
      const name = payload.name || "unknown";
      let args = {};
      try {
        args = typeof payload.arguments === "string" ? JSON.parse(payload.arguments) : payload.arguments || {};
      } catch {
        args = {};
      }

      let lane = null;
      if (CODEX_SHELL_TOOLS.has(name)) {
        const command = args.cmd || args.command || (Array.isArray(args.argv) ? args.argv.join(" ") : "");
        lane = recordShellCommand(session, command);
      } else if (CODEX_WRITE_TOOLS.has(name)) {
        bump(session.toolCalls, "Write");
        recordFileWrite(session, args.path || args.file_path, args.content || args.patch || payload.arguments);
      } else if (CODEX_READ_TOOLS.has(name)) {
        bump(session.toolCalls, "Read");
        lane = "fileRead";
      } else {
        bump(session.toolCalls, name);
        if (name.startsWith("mcp") || name.includes("__")) {
          bump(session.mcpCalls, name);
          lane = "mcp";
        }
      }
      if (payload.call_id || payload.id) pendingLane.set(payload.call_id || payload.id, lane);
      continue;
    }

    if (payload.type === "function_call_output" || payload.type === "custom_tool_call_output") {
      const key = payload.call_id || payload.id;
      const lane = key ? pendingLane.get(key) : null;
      if (key) pendingLane.delete(key);
      const output = payload.output;
      const text = typeof output === "string" ? output : JSON.stringify(output || "");
      session.resultSizes.push(text.length);
      if (lane && session.lanes[lane]) {
        session.lanes[lane].calls += 1;
        session.lanes[lane].bytes += text.length;
      }
      continue;
    }

    if (payload.type === "tool_search_call") {
      bump(session.toolCalls, "ToolSearch");
    }
  }

  return session.turns > 0 || session.bashCount > 0 ? session : null;
}

// --- Gemini CLI ------------------------------------------------------------
//
// Gemini writes ~/.gemini/tmp/<hash>/logs.json: a JSON array of message
// records. It carries no token telemetry, so sessions contribute tool-usage
// evidence only and the report must not present cost figures for them.

export function parseGeminiSession(path) {
  let raw;
  try {
    raw = readFileSync(path, "utf8");
  } catch {
    return null;
  }

  let records;
  try {
    records = JSON.parse(raw);
  } catch {
    return null;
  }
  if (!Array.isArray(records) || records.length === 0) return null;

  const session = emptyNormalized(path);
  session.client = "gemini";
  session.lines = records.length;
  // Gemini's local logs carry no usage fields; flag that so cost reporting can
  // exclude this client rather than treating zero as free.
  session.usageUnavailable = true;

  for (const record of records) {
    const type = record?.type || record?.role;
    if (type === "user") continue;
    const message = record?.message ?? record?.text ?? "";
    if (typeof message === "string") session.assistantProseChars += message.length;
  }

  return session.lines > 0 ? session : null;
}

// --- Registry --------------------------------------------------------------

export const ADAPTERS = {
  codex: { parse: parseCodexSession, match: /rollout-.*\.jsonl$/, usage: true },
  gemini: { parse: parseGeminiSession, match: /logs\.json$/, usage: false },
};

export function adapterFor(clientId) {
  return ADAPTERS[clientId] || null;
}
