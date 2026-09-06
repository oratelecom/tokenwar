// Structured log parser for agent session logs.
//
// Replaces regex line-grepping. A JSONL line is a whole message object that may
// carry several tool_use blocks, so counting matching lines counts neither tool
// calls nor tokens. Everything here iterates message.content[] and keys off
// tool_use.id, and every token number comes from the provider's own usage
// fields rather than from an estimate.

import { readdirSync, readFileSync, statSync, existsSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";

export const MAX_DEPTH = 6;

// Bash argv[0] families. Used for profile inference; a command is attributed to
// the first family that matches, so order matters where a binary could fit two.
export const COMMAND_FAMILIES = {
  devops: /^(ssh|scp|rsync|systemctl|journalctl|docker|docker-compose|kubectl|helm|terraform|ansible|ansible-playbook|gcloud|aws|az|caddy|nginx|apache2ctl|supervisorctl|crontab|ufw|iptables|certbot|service|df|du|free|top|htop|uptime|lsof|netstat|ss)$/,
  test: /^(pytest|jest|vitest|bats|phpunit|tox|nose|nose2|mocha|ava|karma|cypress|playwright|shellcheck)$/,
  build: /^(npm|pnpm|yarn|bun|node|python|python3|pip|pip3|poetry|cargo|go|php|composer|mvn|gradle|tsc|make|just|rake|dotnet)$/,
  vcs: /^(git|gh|glab|hg|svn)$/,
  search: /^(rg|grep|egrep|fgrep|find|fd|ag|ack|locate)$/,
  read: /^(cat|head|tail|sed|less|more|nl|bat|od|xxd|strings)$/,
  data: /^(jq|yq|awk|sort|uniq|wc|cut|paste|tr|column|comm|join)$/,
  web: /^(curl|wget|http|httpie|lynx|w3m)$/,
  db: /^(psql|mysql|sqlite3|mongo|mongosh|redis-cli|alembic|prisma)$/,
};

// Wrappers that prefix a real command. We unwrap to find the command that
// actually ran, otherwise every sudo/env call is attributed to the wrapper.
// `flagsWithValue` lists short options that consume the following token, and
// `leadingOperand` marks wrappers whose first bare argument is their own
// operand rather than the wrapped command (timeout's duration, nice's level).
const WRAPPERS = new Map([
  ["sudo", { flagsWithValue: new Set(["-u", "-g", "-p", "-C", "-h", "-r", "-t", "-U"]) }],
  ["env", {}],
  ["time", {}],
  ["nohup", {}],
  ["xargs", { flagsWithValue: new Set(["-n", "-P", "-I", "-d", "-s", "-L"]) }],
  ["nice", { flagsWithValue: new Set(["-n"]), leadingOperand: /^-?\d+$/ }],
  ["ionice", { flagsWithValue: new Set(["-c", "-n", "-p"]) }],
  ["command", {}],
  ["exec", {}],
  ["builtin", {}],
  ["timeout", { flagsWithValue: new Set(["-s", "-k"]), leadingOperand: /^\d+(?:\.\d+)?[smhd]?$/ }],
  ["stdbuf", { flagsWithValue: new Set(["-i", "-o", "-e"]) }],
  ["rtk", {}],
]);

// Shell keywords and punctuation that are syntax, never a command name.
const SHELL_SYNTAX = /^(do|done|then|fi|else|elif|esac|for|while|until|if|case|function|in|select|coproc)$/;

// Shell operators that separate independent commands within one Bash call.
const SPLIT_RE = /\s*(?:\|\||&&|\||;|\n)\s*/;

export function expandHome(path) {
  return path.startsWith("~/") ? join(homedir(), path.slice(2)) : path;
}

// Tokenize a shell command well enough to recover argv[0]. This never executes
// anything; it only needs to survive quoting to find the head binary.
export function commandHead(segment) {
  const trimmed = segment.trim();
  if (!trimmed) return null;

  const tokens = [];
  let current = "";
  let quote = null;
  for (let i = 0; i < trimmed.length; i += 1) {
    const ch = trimmed[i];
    if (quote) {
      if (ch === "\\" && quote === '"' && i + 1 < trimmed.length) {
        current += trimmed[i + 1];
        i += 1;
      } else if (ch === quote) {
        quote = null;
      } else {
        current += ch;
      }
      continue;
    }
    if (ch === "'" || ch === '"') {
      quote = ch;
      continue;
    }
    if (ch === "\\" && i + 1 < trimmed.length) {
      current += trimmed[i + 1];
      i += 1;
      continue;
    }
    if (/\s/.test(ch)) {
      if (current) tokens.push(current);
      current = "";
      continue;
    }
    current += ch;
  }
  if (current) tokens.push(current);

  // Skip leading VAR=value assignments and wrapper commands.
  let index = 0;
  while (index < tokens.length) {
    const token = tokens[index];
    if (/^[A-Za-z_][A-Za-z0-9_]*=/.test(token)) {
      index += 1;
      continue;
    }
    const base = token.replace(/^.*\//, "");
    const wrapper = WRAPPERS.get(base);
    if (!wrapper) break;

    index += 1;
    // Skip the wrapper's own options. An option that takes a value consumes the
    // next token too, otherwise `sudo -u deploy docker ps` reports `deploy`.
    while (index < tokens.length && tokens[index].startsWith("-")) {
      const flag = tokens[index];
      index += 1;
      const takesValue = wrapper.flagsWithValue?.has(flag) && !flag.includes("=");
      if (takesValue && index < tokens.length) index += 1;
    }
    // Some wrappers take a bare operand before the command (timeout's duration).
    if (wrapper.leadingOperand && index < tokens.length && wrapper.leadingOperand.test(tokens[index])) {
      index += 1;
    }
  }
  if (index >= tokens.length) return null;

  const head = tokens[index].replace(/^.*\//, "");
  // Shell syntax and punctuation are not commands.
  if (!head || /^[({[\]})<>&|$"'`;]/.test(head) || SHELL_SYNTAX.test(head)) {
    return null;
  }
  const sub = tokens[index + 1] && !tokens[index + 1].startsWith("-") ? tokens[index + 1] : null;
  return { head, sub, argv: tokens.slice(index) };
}

export function classifyCommand(head) {
  if (!head) return null;
  for (const [family, re] of Object.entries(COMMAND_FAMILIES)) {
    if (re.test(head)) return family;
  }
  return "other";
}

// Split one Bash tool input into the individual commands it runs.
export function splitCommands(command) {
  if (!command) return [];
  return String(command)
    .split(SPLIT_RE)
    .map((segment) => commandHead(segment))
    .filter(Boolean);
}

export function listSessionFiles(root, { maxFiles = Infinity, since = null } = {}) {
  if (!existsSync(root)) return [];
  const found = [];
  const stack = [{ path: root, depth: 0 }];
  while (stack.length > 0) {
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
        if (current.depth < MAX_DEPTH && entry.name !== "node_modules") {
          stack.push({ path, depth: current.depth + 1 });
        }
        continue;
      }
      if (!entry.isFile() || !entry.name.endsWith(".jsonl")) continue;
      let stats;
      try {
        stats = statSync(path);
      } catch {
        continue;
      }
      if (since && stats.mtimeMs < since) continue;
      found.push({ path, mtimeMs: stats.mtimeMs, size: stats.size });
    }
  }
  found.sort((left, right) => right.mtimeMs - left.mtimeMs);
  return Number.isFinite(maxFiles) ? found.slice(0, maxFiles) : found;
}

function emptySession(path) {
  return {
    path,
    sessionId: null,
    cwd: null,
    gitBranch: null,
    model: null,
    turns: 0,
    // Provider-reported usage. Never estimated.
    freshInput: 0,
    cacheCreate: 0,
    cacheRead: 0,
    output: 0,
    // Cache behaviour: how often the prefix had to be rebuilt after turn 1.
    cacheWriteTurns: 0,
    cacheWriteTokensAfterFirst: 0,
    cacheReadTurns: 0,
    firstRequestTokens: 0,
    peakInputTokens: 0,
    compactions: 0,
    toolCalls: new Map(),
    bashFamilies: new Map(),
    bashHeads: new Map(),
    bashCount: 0,
    fileExtensions: new Map(),
    skillsInvoked: new Map(),
    mcpCalls: new Map(),
    // Per-lane result payload, matched back to the call that produced it.
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

function resultText(block) {
  const content = block?.content;
  if (typeof content === "string") return content;
  if (Array.isArray(content)) {
    return content.map((part) => (typeof part === "string" ? part : part?.text || "")).join("");
  }
  if (content == null) return "";
  try {
    return JSON.stringify(content);
  } catch {
    return "";
  }
}

// Map a tool call to the lane whose cost it drives, so a recommendation can be
// tied to the payload it would actually reduce.
function laneForCall(name, family) {
  if (name === "Bash") {
    if (family === "search") return "search";
    if (family === "read") return "read";
    if (family === "web") return "web";
    if (family === "test") return "test";
    return "shell";
  }
  if (name === "Read" || name === "NotebookRead") return "fileRead";
  if (name === "Grep" || name === "Glob") return "search";
  if (name === "WebFetch" || name === "WebSearch") return "web";
  if (typeof name === "string" && name.startsWith("mcp__")) return "mcp";
  return null;
}

// Parse one session file. Returns null when the file holds no usable turns.
export function parseSessionFile(path, { includeSidechain = false } = {}) {
  let raw;
  try {
    raw = readFileSync(path, "utf8");
  } catch {
    return null;
  }

  const session = emptySession(path);
  // tool_use.id -> {name, family, lane}; lets a result be attributed to its call.
  const pending = new Map();
  const seenCallIds = new Set();
  let firstUsageSeen = false;

  for (const line of raw.split("\n")) {
    if (!line) continue;
    session.lines += 1;
    let event;
    try {
      event = JSON.parse(line);
    } catch {
      // A truncated tail line is expected when a session is still being written.
      session.parseErrors += 1;
      continue;
    }

    if (!session.sessionId && event.sessionId) session.sessionId = event.sessionId;
    if (!session.cwd && event.cwd) session.cwd = event.cwd;
    if (!session.gitBranch && event.gitBranch) session.gitBranch = event.gitBranch;

    const isSidechain = event.isSidechain === true;
    const message = event.message;

    // Skill invocation ground truth, when the client records it.
    if (event.attributionSkill) bump(session.skillsInvoked, event.attributionSkill);
    if (event.type === "summary" || event.isCompactSummary) session.compactions += 1;

    const usage = message?.usage;
    if (usage && !isSidechain) {
      if (!session.model && message?.model) session.model = message.model;
      const fresh = usage.input_tokens || 0;
      const create = usage.cache_creation_input_tokens || 0;
      const read = usage.cache_read_input_tokens || 0;
      session.turns += 1;
      session.freshInput += fresh;
      session.cacheCreate += create;
      session.cacheRead += read;
      session.output += usage.output_tokens || 0;

      const presented = fresh + create + read;
      if (presented > session.peakInputTokens) session.peakInputTokens = presented;
      if (!firstUsageSeen) {
        session.firstRequestTokens = presented;
        firstUsageSeen = true;
      } else if (create > 0) {
        // A cache write after turn 1 means the prefix changed and had to be
        // rebuilt at 1.25x instead of read at 0.1x.
        session.cacheWriteTurns += 1;
        session.cacheWriteTokensAfterFirst += create;
      }
      if (read > 0) session.cacheReadTurns += 1;
    }

    const content = message?.content;
    if (!Array.isArray(content)) continue;

    for (const block of content) {
      if (block?.type === "text" && message?.role === "assistant" && !isSidechain) {
        session.assistantProseChars += (block.text || "").length;
        continue;
      }

      if (block?.type === "tool_use") {
        // Deduplicate: the same call can appear again on retry or resume.
        if (block.id && seenCallIds.has(block.id)) continue;
        if (block.id) seenCallIds.add(block.id);
        if (isSidechain) {
          session.sidechainCalls += 1;
          if (!includeSidechain) continue;
        }

        const name = block.name;
        bump(session.toolCalls, name);
        if (typeof name === "string" && name.startsWith("mcp__")) bump(session.mcpCalls, name);
        if (name === "Skill" && block.input?.skill) bump(session.skillsInvoked, block.input.skill);

        let family = null;
        if (name === "Bash" && block.input?.command) {
          session.bashCount += 1;
          const commands = splitCommands(block.input.command);
          for (const entry of commands) {
            bump(session.bashHeads, entry.head);
            bump(session.bashFamilies, classifyCommand(entry.head));
          }
          // The lane of a compound command is set by its first real command.
          family = commands.length ? classifyCommand(commands[0].head) : null;
        }

        if ((name === "Write" || name === "Edit" || name === "NotebookEdit") && block.input?.file_path) {
          const ext = String(block.input.file_path).split("/").pop().split(".").pop().toLowerCase();
          if (ext && ext.length <= 6) bump(session.fileExtensions, ext);
          const written = block.input.content || block.input.new_string || "";
          session.codeWrittenChars += String(written).length;
        }

        const lane = laneForCall(name, family);
        if (block.id) pending.set(block.id, { name, family, lane });
        continue;
      }

      if (block?.type === "tool_result") {
        const call = block.tool_use_id ? pending.get(block.tool_use_id) : null;
        if (!call) continue;
        pending.delete(block.tool_use_id);
        const bytes = resultText(block).length;
        session.resultSizes.push(bytes);
        if (call.lane && session.lanes[call.lane]) {
          session.lanes[call.lane].calls += 1;
          session.lanes[call.lane].bytes += bytes;
        }
      }
    }
  }

  return session.turns > 0 || session.bashCount > 0 ? session : null;
}

function mergeMap(target, source) {
  for (const [key, value] of source) bump(target, key, value);
}

export function aggregateSessions(sessions) {
  const total = {
    sessions: sessions.length,
    turns: 0,
    freshInput: 0,
    cacheCreate: 0,
    cacheRead: 0,
    output: 0,
    cacheWriteTurns: 0,
    cacheWriteTokensAfterFirst: 0,
    cacheReadTurns: 0,
    compactions: 0,
    bashCount: 0,
    sidechainCalls: 0,
    assistantProseChars: 0,
    codeWrittenChars: 0,
    toolCalls: new Map(),
    bashFamilies: new Map(),
    bashHeads: new Map(),
    fileExtensions: new Map(),
    skillsInvoked: new Map(),
    mcpCalls: new Map(),
    lanes: {},
    firstRequestTokens: [],
    peakInputTokens: [],
    resultSizes: [],
    cwds: new Set(),
  };

  for (const key of Object.keys(emptySession("").lanes)) {
    total.lanes[key] = { calls: 0, bytes: 0 };
  }

  for (const session of sessions) {
    total.turns += session.turns;
    total.freshInput += session.freshInput;
    total.cacheCreate += session.cacheCreate;
    total.cacheRead += session.cacheRead;
    total.output += session.output;
    total.cacheWriteTurns += session.cacheWriteTurns;
    total.cacheWriteTokensAfterFirst += session.cacheWriteTokensAfterFirst;
    total.cacheReadTurns += session.cacheReadTurns;
    total.compactions += session.compactions;
    total.bashCount += session.bashCount;
    total.sidechainCalls += session.sidechainCalls;
    total.assistantProseChars += session.assistantProseChars;
    total.codeWrittenChars += session.codeWrittenChars;
    mergeMap(total.toolCalls, session.toolCalls);
    mergeMap(total.bashFamilies, session.bashFamilies);
    mergeMap(total.bashHeads, session.bashHeads);
    mergeMap(total.fileExtensions, session.fileExtensions);
    mergeMap(total.skillsInvoked, session.skillsInvoked);
    mergeMap(total.mcpCalls, session.mcpCalls);
    for (const [lane, value] of Object.entries(session.lanes)) {
      total.lanes[lane].calls += value.calls;
      total.lanes[lane].bytes += value.bytes;
    }
    if (session.firstRequestTokens > 0) total.firstRequestTokens.push(session.firstRequestTokens);
    if (session.peakInputTokens > 0) total.peakInputTokens.push(session.peakInputTokens);
    for (const size of session.resultSizes) total.resultSizes.push(size);
    if (session.cwd) total.cwds.add(session.cwd);
  }

  return total;
}

export function percentile(values, p) {
  if (!values.length) return 0;
  const sorted = [...values].sort((left, right) => left - right);
  const index = Math.min(sorted.length - 1, Math.max(0, Math.ceil((p / 100) * sorted.length) - 1));
  return sorted[index];
}

export function median(values) {
  return percentile(values, 50);
}
