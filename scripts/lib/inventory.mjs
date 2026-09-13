// Installed-capability inventory: what is loaded into every request, and what
// was actually invoked.
//
// This is the part of the scan that needs no modelling at all. The listing cost
// is measured from the files on disk, and usage is counted from the logs, so
// "installed but never invoked" is an observation rather than an estimate.

import { readdirSync, readFileSync, existsSync, statSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";

// Characters per token. Only ever applied to text we are approximating the
// prompt cost of; never to provider-reported usage, which is exact.
export const CHARS_PER_TOKEN = 4;

// Directories where a plugin vendors its skills for another agent. These copies
// are not loaded by the client being audited, so counting them would inflate
// both the skill count and the per-request listing cost.
const VENDORED_COPY_RE = /\/(\.junie|\.codex|\.cursor|\.gemini|\.github|\.opencode|\.windsurf|\.aider|node_modules|test|tests|fixtures|__tests__)\//;

export function estimateTokens(text) {
  return Math.ceil((text || "").length / CHARS_PER_TOKEN);
}

function readFrontmatter(text) {
  const match = text.match(/^---\r?\n([\s\S]*?)\r?\n---/);
  if (!match) return {};
  const block = match[1];
  const fields = {};
  const nameMatch = block.match(/^name:\s*(.+)$/m);
  if (nameMatch) fields.name = nameMatch[1].trim().replace(/^["']|["']$/g, "");
  // A description may be a plain scalar or a YAML block scalar (`>` or `|`),
  // whose text lives on the following indented lines. Read to the next
  // top-level key so both shapes are captured; matching only to end of line
  // would score a folded description as a few tokens instead of its real size.
  const descMatch = block.match(/^description:[ \t]*(.*(?:\n(?:[ \t]+.*|[ \t]*))*)/m);
  if (descMatch) {
    fields.description = descMatch[1]
      .replace(/^[>|][-+]?\s*/, "")
      .split("\n")
      .map((line) => line.trim())
      .join(" ")
      .trim()
      .replace(/^["']|["']$/g, "");
  }
  return fields;
}

// The per-request cost of one skill is its name plus description as they appear
// in the listing, not the whole SKILL.md (that is only read on invocation).
function listingCost(name, description) {
  return estimateTokens(name) + estimateTokens(description) + 4;
}

export function collectSkills({ skillsDir, pluginCacheDir } = {}) {
  const home = homedir();
  // Env overrides keep the scan testable against a fixture directory instead of
  // whatever the host happens to have installed.
  const userDir = skillsDir || process.env.TOKENWAR_SKILLS_DIR || join(home, ".claude", "skills");
  const pluginDir =
    pluginCacheDir || process.env.TOKENWAR_PLUGIN_CACHE_DIR || join(home, ".claude", "plugins", "cache");
  const skills = [];

  if (existsSync(userDir)) {
    for (const entry of readdirSync(userDir, { withFileTypes: true })) {
      if (!entry.isDirectory() || entry.name.startsWith(".")) continue;
      const path = join(userDir, entry.name, "SKILL.md");
      if (!existsSync(path)) continue;
      let text;
      try {
        text = readFileSync(path, "utf8");
      } catch {
        continue;
      }
      const fields = readFrontmatter(text);
      const name = fields.name || entry.name;
      skills.push({
        name,
        dirName: entry.name,
        source: "user",
        path,
        listingTokens: listingCost(name, fields.description),
        bodyTokens: estimateTokens(text),
      });
    }
  }

  if (existsSync(pluginDir)) {
    const stack = [{ path: pluginDir, depth: 0 }];
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
          if (current.depth < 7 && entry.name !== "node_modules") {
            stack.push({ path, depth: current.depth + 1 });
          }
          continue;
        }
        if (entry.name !== "SKILL.md") continue;
        // A plugin often vendors the same skill for several agents (.junie/,
        // .codex/, .cursor/ ...). Only the copy the client loads costs prompt
        // space, so count a plugin skill once rather than once per vendored copy.
        if (VENDORED_COPY_RE.test(path)) continue;
        let text;
        try {
          text = readFileSync(path, "utf8");
        } catch {
          continue;
        }
        const fields = readFrontmatter(text);
        const name = fields.name || entry.name;
        skills.push({
          name,
          dirName: name,
          source: "plugin",
          path,
          listingTokens: listingCost(name, fields.description),
          bodyTokens: estimateTokens(text),
        });
      }
    }
  }

  // The same skill name can still appear under two plugin paths (a versioned
  // cache alongside a working copy). The client loads one listing entry per
  // name, so keep the richest parse and drop the rest.
  const byName = new Map();
  for (const skill of skills) {
    const key = `${skill.source}:${skill.name}`;
    const existing = byName.get(key);
    if (!existing || skill.listingTokens > existing.listingTokens) byName.set(key, skill);
  }
  return [...byName.values()];
}

// MCP servers as configured. Tool counts come from the live session when the
// caller supplies them, because a server's tool list is only knowable at
// connect time.
export function collectMcpServers({ configPath, knownToolCounts = {} } = {}) {
  const path = configPath || process.env.TOKENWAR_MCP_CONFIG || join(homedir(), ".claude.json");
  const servers = new Map();

  if (existsSync(path)) {
    let config;
    try {
      config = JSON.parse(readFileSync(path, "utf8"));
    } catch {
      config = null;
    }
    if (config) {
      for (const name of Object.keys(config.mcpServers || {})) {
        servers.set(name, { name, scope: "global", toolCount: knownToolCounts[name] || null });
      }
      for (const [project, value] of Object.entries(config.projects || {})) {
        for (const name of Object.keys(value?.mcpServers || {})) {
          if (!servers.has(name)) {
            servers.set(name, { name, scope: `project:${project}`, toolCount: knownToolCounts[name] || null });
          }
        }
      }
    }
  }

  for (const [name, toolCount] of Object.entries(knownToolCounts)) {
    if (!servers.has(name)) servers.set(name, { name, scope: "session", toolCount });
  }

  return [...servers.values()];
}

// Cross installed capabilities against what the logs show was invoked.
export function crossReference({ skills, mcpServers, skillsInvoked, mcpCalls }) {
  const invoked = new Set();
  for (const key of skillsInvoked.keys()) {
    invoked.add(key);
    // Plugin skills are invoked as "plugin:skill"; record the bare name too so
    // a plugin-scoped invocation still marks the skill as used.
    if (key.includes(":")) invoked.add(key.split(":").pop());
  }

  const usedSkills = [];
  const deadSkills = [];
  for (const skill of skills) {
    const isUsed = invoked.has(skill.name) || invoked.has(skill.dirName);
    (isUsed ? usedSkills : deadSkills).push({
      ...skill,
      invocations: (skillsInvoked.get(skill.name) || 0) + (skillsInvoked.get(skill.dirName) || 0),
    });
  }

  // Attribute each MCP call to its server so a server with zero calls stands out.
  const callsByServer = new Map();
  for (const [tool, count] of mcpCalls) {
    const parts = tool.split("__");
    const server = parts.length >= 2 ? parts[1] : tool;
    callsByServer.set(server, (callsByServer.get(server) || 0) + count);
  }

  const servers = mcpServers.map((server) => ({
    ...server,
    calls: callsByServer.get(server.name) || 0,
  }));
  for (const [server, calls] of callsByServer) {
    if (!servers.some((item) => item.name === server)) {
      servers.push({ name: server, scope: "session", toolCount: null, calls });
    }
  }

  const deadServers = servers.filter((server) => server.calls === 0);

  const listingTokens = skills.reduce((sum, skill) => sum + skill.listingTokens, 0);
  const deadListingTokens = deadSkills.reduce((sum, skill) => sum + skill.listingTokens, 0);

  return {
    skills: { all: skills, used: usedSkills, dead: deadSkills, listingTokens, deadListingTokens },
    mcp: { servers, dead: deadServers },
  };
}
