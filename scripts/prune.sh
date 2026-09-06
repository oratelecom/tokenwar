#!/usr/bin/env bash
# tokenwar prune — list capabilities that load on every request but were never
# invoked in the scanned window.
#
# This command never deletes anything. Skills and MCP servers live in the user's
# own configuration, and "not used in the last 30 days" is not "unwanted": a
# release skill may be invoked twice a year and still be worth its listing cost.
# It prints the evidence and the exact commands, and the user decides.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

command -v node >/dev/null 2>&1 || {
    printf 'tokenwar prune: node is required (v18+).\n' >&2
    exit 127
}

days=30
for arg in "$@"; do
    case "$arg" in
        -h|--help)
            cat <<'EOF'
tokenwar prune — show capabilities loaded on every request but never invoked

Usage:
  tokenwar prune [--days N]

Prints never-invoked skills and MCP servers with their per-request cost, and the
commands to remove them. Nothing is deleted: infrequent use is not disuse, so
the decision stays with you.
EOF
            exit 0
            ;;
        --days) shift; days="${1:-30}" ;;
    esac
    shift || true
done

export TOKENWAR_STATUS_SCRIPT="${TOKENWAR_STATUS_SCRIPT:-${SCRIPT_DIR}/status.sh}"

node "${SCRIPT_DIR}/scan.mjs" --days "$days" --json | node -e '
let raw = "";
process.stdin.on("data", (chunk) => { raw += chunk; });
process.stdin.on("end", () => {
  const report = JSON.parse(raw);
  const skills = report.inventory.skills;
  const mcp = report.inventory.mcp;
  const days = report.meta.window;

  console.log("");
  console.log(`  TOKENWAR PRUNE   ${report.meta.sessions} sessions over ${days}`);
  console.log("  " + "-".repeat(72));
  console.log("");

  if (skills.dead.length === 0) {
    console.log("  Every installed skill was invoked at least once. Nothing to review.");
  } else {
    console.log(`  ${skills.dead.length} of ${skills.total} skills were never invoked.`);
    console.log(`  Together they add ${skills.deadListingTokens.toLocaleString()} tokens to every request.`);
    console.log("");
    const sorted = [...skills.dead].sort((a, b) => b.listingTokens - a.listingTokens);
    for (const skill of sorted) {
      console.log(`    ${String(skill.listingTokens).padStart(5)} tok  ${skill.name}${skill.source === "plugin" ? "  (plugin)" : ""}`);
    }
    console.log("");
    const user = sorted.filter((s) => s.source === "user");
    if (user.length > 0) {
      console.log("  To remove a user skill, delete its directory:");
      console.log(`    rm -rf ~/.claude/skills/<name>`);
      console.log("");
    }
    const plugins = sorted.filter((s) => s.source === "plugin");
    if (plugins.length > 0) {
      console.log("  Plugin skills come with their plugin; disable the plugin to drop them:");
      console.log("    claude plugin disable <plugin>");
      console.log("");
    }
  }

  if (mcp.dead.length > 0) {
    console.log(`  ${mcp.dead.length} MCP servers were never called:`);
    for (const server of mcp.dead) {
      const tools = server.toolCount ? `${server.toolCount} tools` : "tool count unknown";
      console.log(`    ${server.name}  (${tools}, ${server.scope})`);
    }
    console.log("");
    console.log("  An unused MCP server costs its tool list on every request, and its full");
    console.log("  schemas on clients that do not defer them. To remove one:");
    console.log("    claude mcp remove <name>");
    console.log("");
  }

  console.log("  Before removing: a skill used twice a year still earns its listing cost.");
  console.log("  This is a review list, not a delete list.");
  console.log("");
});
'
