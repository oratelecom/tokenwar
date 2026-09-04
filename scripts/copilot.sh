#!/usr/bin/env bash
# tokenwar copilot — report and wire the token-saving stack into GitHub Copilot CLI.
#
# Copilot CLI is a first-class tokenwar provider (native token telemetry in
# ~/.copilot/session-store.db), but the TOOLS do not reach it for free: each one
# is published for Claude Code and has to be pointed at Copilot's own extension
# points. Copilot offers exactly three:
#
#   hooks   ~/.copilot/hooks/*.json          — PreToolUse command rewriting
#   skills  ~/.copilot/skills/<name>/SKILL.md — the portable Agent-Skills format
#   MCP     ~/.copilot/mcp-config.json        — stdio/HTTP servers
#
# So the stack maps like this:
#
#   rtk         → hook       `rtk init -g --copilot`
#   graphify    → skill      `graphify copilot install` (its own native command)
#   caveman     → skill      copied from the Claude plugin cache
#   ponytail    → skill      copied from the Claude plugin cache
#   claude-mem  → MCP        its own .mcp.json definition, re-registered
#
#   context-mode / pxpipe → not wired, on purpose. See NOT_WIRED_REASON_* below.
#
# Usage:
#   copilot.sh            # check (read-only). Exit 0 if every wireable tool is wired.
#   copilot.sh check
#   copilot.sh wire       # apply the missing wiring (asks confirmation)
#   copilot.sh wire --yes # apply without prompting

set -uo pipefail

readonly COPILOT_BIN="copilot"
readonly RTK_BIN="rtk"
readonly GRAPHIFY_BIN="graphify"

# COPILOT_HOME is Copilot CLI's own override for its config + state dir.
readonly COPILOT_HOME="${COPILOT_HOME:-${HOME}/.copilot}"
readonly COPILOT_SKILLS_DIR="${COPILOT_HOME}/skills"
readonly COPILOT_HOOKS_DIR="${COPILOT_HOME}/hooks"
readonly COPILOT_RTK_HOOK="${COPILOT_HOOKS_DIR}/rtk-rewrite.json"
readonly COPILOT_MCP_CONFIG="${COPILOT_HOME}/mcp-config.json"

readonly CLAUDE_PLUGIN_CACHE="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/plugins/cache"
readonly CAVEMAN_CACHE_REL="caveman/caveman"
readonly PONYTAIL_CACHE_REL="ponytail/ponytail"
readonly CLAUDE_MEM_CACHE_REL="thedotmack/claude-mem"
readonly CLAUDE_MEM_MCP_MANIFEST=".mcp.json"
# The key claude-mem uses for its server inside its own .mcp.json, and the name
# we register it under in Copilot. They differ on purpose: "mcp-search" is an
# implementation detail, "claude-mem" is what a user recognises in `mcp list`.
readonly CLAUDE_MEM_MCP_SOURCE_KEY="mcp-search"
readonly CLAUDE_MEM_MCP_SERVER_NAME="claude-mem"

# claude-mem's MCP server talks to a local worker daemon over HTTP, and its own
# client aborts at CLAUDE_MEM_API_TIMEOUT_MS (30s by default). The first search
# after a cold worker path builds an index over the whole memory DB and measured
# 2m02s here, so the default guarantees a timeout on the very first call — which
# reads as "claude-mem is broken under Copilot" when it is not. Both timeouts
# (claude-mem's own, and Copilot's per-tool one) are raised to cover it.
readonly CLAUDE_MEM_API_TIMEOUT_MS=180000
readonly COPILOT_MCP_TIMEOUT_MS=200000

readonly SKILL_MANIFEST="SKILL.md"

readonly STATE_OK="wired"
readonly STATE_NOT_WIRED="not-wired"
readonly STATE_SOURCE_MISSING="source-missing"
readonly STATE_NA="n/a"

readonly NOT_WIRED_REASON_CTX="MCP server, but its plugin manifest pins an absolute, version-specific interpreter path — registering it would break on the next context-mode upgrade"
readonly NOT_WIRED_REASON_PXPIPE="proxy on the Anthropic-compatible API path; Copilot CLI talks to GitHub's endpoint, so there is nothing for it to sit in front of"

readonly EXIT_USAGE=2

readonly COL_GREEN=$'\033[32m'
readonly COL_RED=$'\033[31m'
readonly COL_YELLOW=$'\033[33m'
readonly COL_DIM=$'\033[2m'
readonly COL_RESET=$'\033[0m'

# Source of the interactive confirmation, overridable via TW_TTY so the confirm
# path is testable without a live tty (same contract as upgrade.sh).
readonly TTY_DEVICE="${TW_TTY:-/dev/tty}"

say()  { printf '%s %s\n' "${COL_GREEN}==>${COL_RESET}" "$*"; }
warn() { printf '%s %s\n' "${COL_YELLOW}!!${COL_RESET}" "$*" >&2; }

usage() {
    cat <<EOF
tokenwar copilot — wire the token-saving stack into GitHub Copilot CLI

Usage:
  tokenwar copilot [check]     report what is wired (read-only)
  tokenwar copilot wire        apply the missing wiring (asks confirmation)
  tokenwar copilot wire --yes  apply without prompting

Wired tools: rtk (hook), graphify + caveman + ponytail (skills), claude-mem (MCP).
context-mode and pxpipe are reported n/a with the reason.
EOF
}

# Newest versioned directory under the Claude plugin cache for <marketplace/plugin>.
# Plugins version by semver (ponytail: 4.9.0) or by git SHA (caveman), so sort by
# mtime rather than by name — a SHA has no order.
newest_plugin_dir() {
    local root="${CLAUDE_PLUGIN_CACHE}/$1"
    [[ -d "$root" ]] || { printf ''; return; }
    local newest=""
    local d
    for d in "$root"/*/; do
        [[ -d "$d" ]] || continue
        if [[ -z "$newest" || "$d" -nt "$newest" ]]; then newest="$d"; fi
    done
    printf '%s' "${newest%/}"
}

caveman_skill_source()  { local d; d=$(newest_plugin_dir "$CAVEMAN_CACHE_REL");  [[ -n "$d" ]] && printf '%s' "${d}/skills/caveman/${SKILL_MANIFEST}"; }
ponytail_skill_source() { local d; d=$(newest_plugin_dir "$PONYTAIL_CACHE_REL"); [[ -n "$d" ]] && printf '%s' "${d}/skills/ponytail/${SKILL_MANIFEST}"; }
claude_mem_mcp_source() { local d; d=$(newest_plugin_dir "$CLAUDE_MEM_CACHE_REL"); [[ -n "$d" ]] && printf '%s' "${d}/${CLAUDE_MEM_MCP_MANIFEST}"; }

skill_installed() { [[ -f "${COPILOT_SKILLS_DIR}/$1/${SKILL_MANIFEST}" ]]; }

# Is <name> already a server in Copilot's user MCP config? Read the file rather
# than shelling out to `copilot mcp list`: the check must work with the CLI
# absent, and the file is the documented user-scope source.
mcp_server_registered() {
    [[ -f "$COPILOT_MCP_CONFIG" ]] || return 1
    MCP_CONFIG="$COPILOT_MCP_CONFIG" MCP_NAME="$1" node --input-type=module -e '
        import { readFileSync } from "node:fs";
        let cfg; try { cfg = JSON.parse(readFileSync(process.env.MCP_CONFIG, "utf8")); } catch { process.exit(1); }
        const servers = cfg.mcpServers || cfg.servers || {};
        process.exit(process.env.MCP_NAME in servers ? 0 : 1);
    ' 2>/dev/null
}

# ── per-tool state ────────────────────────────────────────────────

state_rtk() {
    command -v "$RTK_BIN" >/dev/null 2>&1 || { echo "$STATE_SOURCE_MISSING"; return; }
    [[ -f "$COPILOT_RTK_HOOK" ]] && echo "$STATE_OK" || echo "$STATE_NOT_WIRED"
}

state_graphify() {
    command -v "$GRAPHIFY_BIN" >/dev/null 2>&1 || { echo "$STATE_SOURCE_MISSING"; return; }
    skill_installed graphify && echo "$STATE_OK" || echo "$STATE_NOT_WIRED"
}

state_caveman() {
    [[ -n "$(caveman_skill_source)" && -f "$(caveman_skill_source)" ]] || { echo "$STATE_SOURCE_MISSING"; return; }
    skill_installed caveman && echo "$STATE_OK" || echo "$STATE_NOT_WIRED"
}

state_ponytail() {
    [[ -n "$(ponytail_skill_source)" && -f "$(ponytail_skill_source)" ]] || { echo "$STATE_SOURCE_MISSING"; return; }
    skill_installed ponytail && echo "$STATE_OK" || echo "$STATE_NOT_WIRED"
}

state_claude_mem() {
    [[ -n "$(claude_mem_mcp_source)" && -f "$(claude_mem_mcp_source)" ]] || { echo "$STATE_SOURCE_MISSING"; return; }
    mcp_server_registered "$CLAUDE_MEM_MCP_SERVER_NAME" && echo "$STATE_OK" || echo "$STATE_NOT_WIRED"
}

# ── per-tool wiring ───────────────────────────────────────────────

wire_rtk() {
    say "rtk → Copilot hook (rtk init -g --copilot --auto-patch)"
    "$RTK_BIN" init -g --copilot --auto-patch >/dev/null 2>&1 \
        || { warn "rtk init -g --copilot failed — run it manually"; return 1; }
}

wire_graphify() {
    say "graphify → Copilot skill (graphify copilot install)"
    "$GRAPHIFY_BIN" copilot install >/dev/null 2>&1 \
        || { warn "graphify copilot install failed — run it manually"; return 1; }
}

# Register a SKILL.md with Copilot. `copilot skill add <file>` materialises it
# into ~/.copilot/skills/<name>/ using the frontmatter name — we never write into
# that directory ourselves, so Copilot stays the owner of its own layout.
wire_skill_from_plugin() {
    local label="$1" src="$2"
    if [[ ! -f "$src" ]]; then
        warn "${label}: skill source not found ($src)"; return 1
    fi
    say "${label} → Copilot skill (copilot skill add)"
    "$COPILOT_BIN" skill add "$src" >/dev/null 2>&1 \
        || { warn "copilot skill add failed for ${label}"; return 1; }
}

wire_caveman()  { wire_skill_from_plugin caveman  "$(caveman_skill_source)"; }
wire_ponytail() { wire_skill_from_plugin ponytail "$(ponytail_skill_source)"; }

# Re-register claude-mem's OWN server definition rather than hand-writing a
# command: the published .mcp.json wraps a locator that finds the current plugin
# version at runtime, so the registration survives claude-mem upgrades. A
# hardcoded path would break on the next `claude plugin update`.
wire_claude_mem() {
    local manifest
    manifest="$(claude_mem_mcp_source)"
    if [[ ! -f "$manifest" ]]; then
        warn "claude-mem: .mcp.json not found in the plugin cache"; return 1
    fi
    local command_bin
    command_bin=$(MANIFEST="$manifest" KEY="$CLAUDE_MEM_MCP_SOURCE_KEY" node --input-type=module -e '
        import { readFileSync } from "node:fs";
        const s = JSON.parse(readFileSync(process.env.MANIFEST, "utf8")).mcpServers[process.env.KEY];
        process.stdout.write(String(s?.command || ""));
    ' 2>/dev/null)
    if [[ -z "$command_bin" ]]; then
        warn "claude-mem: no '${CLAUDE_MEM_MCP_SOURCE_KEY}' server in $manifest"; return 1
    fi
    local server_args=()
    mapfile -t server_args < <(MANIFEST="$manifest" KEY="$CLAUDE_MEM_MCP_SOURCE_KEY" node --input-type=module -e '
        import { readFileSync } from "node:fs";
        const s = JSON.parse(readFileSync(process.env.MANIFEST, "utf8")).mcpServers[process.env.KEY];
        for (const a of (s?.args || [])) console.log(a);
    ' 2>/dev/null)

    say "claude-mem → Copilot MCP server '${CLAUDE_MEM_MCP_SERVER_NAME}'"
    "$COPILOT_BIN" mcp add "$CLAUDE_MEM_MCP_SERVER_NAME" \
        --env "CLAUDE_MEM_API_TIMEOUT_MS=${CLAUDE_MEM_API_TIMEOUT_MS}" \
        --timeout "$COPILOT_MCP_TIMEOUT_MS" \
        -- "$command_bin" "${server_args[@]}" >/dev/null 2>&1 \
        || { warn "copilot mcp add ${CLAUDE_MEM_MCP_SERVER_NAME} failed"; return 1; }
}

# ── report ────────────────────────────────────────────────────────

format_row() {
    local tool="$1" mechanism="$2" state="$3" note="${4:-}"
    local color symbol
    case "$state" in
        "$STATE_OK")             color="$COL_GREEN";  symbol="✓" ;;
        "$STATE_NOT_WIRED")      color="$COL_RED";    symbol="✗" ;;
        "$STATE_SOURCE_MISSING") color="$COL_YELLOW"; symbol="⚠" ;;
        *)                       color="$COL_DIM";    symbol="·" ;;
    esac
    printf "  %s%s%s  %-12s  %-8s  %-16s  %s%s%s\n" \
        "$color" "$symbol" "$COL_RESET" "$tool" "$mechanism" "$state" \
        "$COL_DIM" "$note" "$COL_RESET"
}

action="${1:-check}"
shift || true
assume_yes=false
for arg in "$@"; do
    case "$arg" in
        --yes) assume_yes=true ;;
        *) echo "unknown arg: $arg" >&2; echo "" >&2; usage >&2; exit "$EXIT_USAGE" ;;
    esac
done
case "$action" in
    check|wire) ;;
    help|-h|--help) usage; exit 0 ;;
    *) echo "unknown action: $action" >&2; echo "" >&2; usage >&2; exit "$EXIT_USAGE" ;;
esac

echo ""
echo "# /tokenwar copilot"
echo ""

if ! command -v "$COPILOT_BIN" >/dev/null 2>&1; then
    warn "GitHub Copilot CLI not installed — nothing to wire (npm install -g @github/copilot)"
    exit 1
fi

rtk_st=$(state_rtk)
graphify_st=$(state_graphify)
caveman_st=$(state_caveman)
ponytail_st=$(state_ponytail)
mem_st=$(state_claude_mem)

printf "  %s  %-12s  %-8s  %-16s  %s\n" "·" "tool" "via" "state" "note"
printf "  ─────────────────────────────────────────────────────────────────\n"
format_row "rtk"          "hook"  "$rtk_st"      "$COPILOT_RTK_HOOK"
format_row "graphify"     "skill" "$graphify_st" "${COPILOT_SKILLS_DIR}/graphify"
format_row "caveman"      "skill" "$caveman_st"  "${COPILOT_SKILLS_DIR}/caveman"
format_row "ponytail"     "skill" "$ponytail_st" "${COPILOT_SKILLS_DIR}/ponytail"
format_row "claude-mem"   "MCP"   "$mem_st"      "${COPILOT_MCP_CONFIG} → ${CLAUDE_MEM_MCP_SERVER_NAME}"
format_row "context-mode" "-"     "$STATE_NA"    "$NOT_WIRED_REASON_CTX"
format_row "pxpipe"       "-"     "$STATE_NA"    "$NOT_WIRED_REASON_PXPIPE"
echo ""

pending=()
[[ "$rtk_st"      == "$STATE_NOT_WIRED" ]] && pending+=(rtk)
[[ "$graphify_st" == "$STATE_NOT_WIRED" ]] && pending+=(graphify)
[[ "$caveman_st"  == "$STATE_NOT_WIRED" ]] && pending+=(caveman)
[[ "$ponytail_st" == "$STATE_NOT_WIRED" ]] && pending+=(ponytail)
[[ "$mem_st"      == "$STATE_NOT_WIRED" ]] && pending+=(claude-mem)

if [[ "$action" == "check" ]]; then
    if (( ${#pending[@]} == 0 )); then
        say "Every installed tool is wired into Copilot."
        exit 0
    fi
    echo "  ${#pending[@]} tool(s) not wired: ${pending[*]}"
    echo "  → Run \`tokenwar copilot wire\` to apply."
    echo ""
    exit 1
fi

# ── wire ──────────────────────────────────────────────────────────
if (( ${#pending[@]} == 0 )); then
    say "Nothing to wire — every installed tool already reaches Copilot."
    exit 0
fi

echo "  will wire: ${pending[*]}"
echo ""
if ! $assume_yes; then
    reply=""
    if { : <"$TTY_DEVICE"; } 2>/dev/null; then
        printf "Wire these into Copilot? [y/N] "
        read -r reply <"$TTY_DEVICE" 2>/dev/null || reply=""
    fi
    case "$reply" in
        y|Y|yes|YES) ;;
        *)
            if [[ -z "$reply" ]]; then
                warn "No interactive terminal — re-run with --yes to apply. Skipped."
            else
                say "Skipped."
            fi
            exit 0
            ;;
    esac
fi

rc=0
for tool in "${pending[@]}"; do
    case "$tool" in
        rtk)        wire_rtk        || rc=1 ;;
        graphify)   wire_graphify   || rc=1 ;;
        caveman)    wire_caveman    || rc=1 ;;
        ponytail)   wire_ponytail   || rc=1 ;;
        claude-mem) wire_claude_mem || rc=1 ;;
    esac
done

echo ""
if (( rc == 0 )); then
    say "Copilot wiring complete. ${COL_DIM}Restart your Copilot CLI session to load it.${COL_RESET}"
else
    warn "One or more wiring steps failed — see the messages above."
fi
exit "$rc"
