#!/usr/bin/env bash
# tokenwar status — report state of the 5 token-saving tools + AI providers.
#
# Exit 0 if all 5 tools are healthy, 1 otherwise. Providers (Codex/Gemini) are
# OPTIONAL — they are reported for information but their absence never fails the
# exit code (a Claude-only host has no codex/gemini and must still exit 0).
# Pass --test to additionally run a liveness ping for each tool
# (note: context-mode ping requires the ctx_stats MCP tool, which
# shell cannot reach — the caller is responsible for that one).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# shellcheck source=lib/providers.sh
source "${SCRIPT_DIR}/lib/providers.sh"

readonly STATUS_OK="OK"
readonly STATUS_DISABLED="installed-disabled"
readonly STATUS_MISSING="not-installed"
readonly STATUS_UNKNOWN="unknown"

readonly SLUG_CTX="context-mode@context-mode"
readonly SLUG_MEM="claude-mem@thedotmack"
readonly SLUG_CAVE="caveman@caveman"
readonly SLUG_PONY="ponytail@ponytail"

readonly RTK_BIN="rtk"
readonly MEM_BIN="claude-mem"
readonly CLAUDE_BIN="claude"

# Cache `claude plugin list --json` output to avoid repeated CLI calls.
PLUGIN_LIST_JSON=""
load_plugin_list() {
    if [[ -z "$PLUGIN_LIST_JSON" ]]; then
        PLUGIN_LIST_JSON="$("$CLAUDE_BIN" plugin list --json 2>/dev/null || echo '[]')"
    fi
}

readonly COL_GREEN=$'\033[32m'
readonly COL_RED=$'\033[31m'
readonly COL_YELLOW=$'\033[33m'
readonly COL_RESET=$'\033[0m'

test_mode=false
for arg in "$@"; do
    case "$arg" in
        --test) test_mode=true ;;
        *) echo "unknown arg: $arg" >&2; exit 2 ;;
    esac
done

# Returns one of: OK | installed-disabled | not-installed | unknown
plugin_state() {
    local slug="$1"
    load_plugin_list
    PLUGIN_QUERY="$slug" PLUGIN_LIST_JSON="$PLUGIN_LIST_JSON" node --input-type=module -e "
        const arr = JSON.parse(process.env.PLUGIN_LIST_JSON || '[]');
        const slug = process.env.PLUGIN_QUERY;
        const entry = arr.find(p => p.id === slug);
        if (!entry)         { console.log('$STATUS_MISSING'); process.exit(0); }
        if (!entry.enabled) { console.log('$STATUS_DISABLED'); process.exit(0); }
        console.log('$STATUS_OK');
    " 2>/dev/null || echo "$STATUS_UNKNOWN"
}

plugin_version() {
    local slug="$1"
    load_plugin_list
    PLUGIN_QUERY="$slug" PLUGIN_LIST_JSON="$PLUGIN_LIST_JSON" node --input-type=module -e "
        const arr = JSON.parse(process.env.PLUGIN_LIST_JSON || '[]');
        const entry = arr.find(p => p.id === process.env.PLUGIN_QUERY);
        console.log(entry?.version || '-');
    " 2>/dev/null || echo "?"
}

# RTK: presence + hook installation
rtk_state() {
    if ! command -v "$RTK_BIN" >/dev/null 2>&1; then
        echo "$STATUS_MISSING"; return
    fi
    # The "[warn] No hook installed" line in `rtk gain` output signals the hook is missing.
    if "$RTK_BIN" gain 2>/dev/null | grep -q "No hook installed"; then
        echo "$STATUS_DISABLED"; return
    fi
    echo "$STATUS_OK"
}

rtk_version() {
    if ! command -v "$RTK_BIN" >/dev/null 2>&1; then echo "-"; return; fi
    "$RTK_BIN" --version 2>/dev/null | awk '{print $2}'
}

# Provider state detection
provider_state_str() {
    provider_is_installed "$1" && echo "$STATUS_OK" || echo "$STATUS_MISSING"
}

format_line() {
    local tool="$1" version="$2" state="$3" extra="${4:-}"
    local color symbol
    case "$state" in
        "$STATUS_OK")        color="$COL_GREEN";  symbol="✓" ;;
        "$STATUS_DISABLED")  color="$COL_YELLOW"; symbol="⚠" ;;
        "$STATUS_MISSING")   color="$COL_RED";    symbol="✗" ;;
        *)                   color="$COL_YELLOW"; symbol="?" ;;
    esac
    printf "  %s%s%s  %-14s  %-10s  %-22s  %s\n" \
        "$color" "$symbol" "$COL_RESET" "$tool" "$version" "$state" "$extra"
}

# Liveness pings used in --test mode (shell-only — caller handles context-mode)
ping_claude_mem() {
    "$MEM_BIN" --version >/dev/null 2>&1
}
ping_rtk() {
    "$RTK_BIN" --version >/dev/null 2>&1 && "$RTK_BIN" gain >/dev/null 2>&1
}
ping_caveman() {
    # caveman is a hook + skill, no CLI ping. Verify on-disk artifacts.
    local cache_root="${HOME}/.claude/plugins/cache/caveman/caveman"
    [[ -d "$cache_root" ]] && find "$cache_root" -mindepth 2 -maxdepth 4 -type d -name skills 2>/dev/null | grep -q .
}
ping_ponytail() {
    # ponytail is a mode-gated plugin, no CLI ping. Alive iff installed + enabled.
    [[ "$(plugin_state "$SLUG_PONY")" == "$STATUS_OK" ]]
}

# === report ===
echo "# /tokenwar status"
echo ""

# ── Tools ──────────────────────────────────────────────────────────
printf "  %s  %-14s  %-10s  %-22s  %s\n" "·" "tool" "version" "state" "note"
printf "  ─────────────────────────────────────────────────────────────────\n"

ctx_state=$(plugin_state "$SLUG_CTX");   ctx_ver=$(plugin_version "$SLUG_CTX")
mem_state=$(plugin_state "$SLUG_MEM");   mem_ver=$(plugin_version "$SLUG_MEM")
cave_state=$(plugin_state "$SLUG_CAVE"); cave_ver=$(plugin_version "$SLUG_CAVE")
pony_state=$(plugin_state "$SLUG_PONY"); pony_ver=$(plugin_version "$SLUG_PONY")
rtk_st=$(rtk_state);                     rtk_ver=$(rtk_version)

ctx_extra=""; mem_extra=""; cave_extra=""; pony_extra=""; rtk_extra=""
if $test_mode; then
    ctx_extra="ping=via MCP (caller)"
    ping_claude_mem && mem_extra="ping=ok" || mem_extra="ping=FAIL"
    ping_rtk        && rtk_extra="ping=ok" || rtk_extra="ping=FAIL"
    ping_caveman    && cave_extra="ping=ok" || cave_extra="ping=FAIL"
    ping_ponytail   && pony_extra="ping=ok" || pony_extra="ping=FAIL"
fi

format_line "context-mode" "$ctx_ver"  "$ctx_state"  "$ctx_extra"
format_line "claude-mem"   "$mem_ver"  "$mem_state"  "$mem_extra"
format_line "rtk"          "$rtk_ver"  "$rtk_st"     "$rtk_extra"
format_line "caveman"      "$cave_ver" "$cave_state" "$cave_extra"
format_line "ponytail"     "$pony_ver" "$pony_state" "$pony_extra"

echo ""

# ── Providers ────────────────────────────────────────────────────────
printf "  %s  %-14s  %-10s  %-22s  %s\n" "·" "provider" "version" "state" "note"
printf "  ─────────────────────────────────────────────────────────────────\n"

# Providers are informational only — we print each one's state but never let an
# uninstalled/absent provider affect the exit code (see exit logic below).
for i in $(seq 0 $((PROVIDER_COUNT - 1))); do
    pid=$(provider_id "$i")
    pname=$(provider_name "$i")
    pver=$(provider_version "$i")
    pstate=$(provider_state_str "$i")

    # Build note: telemetry source
    case "$pid" in
        claude) pnote="telemetry: RTK + ctx_stats + chroma-sync-state" ;;
        codex)  pnote="telemetry: ~/.codex/state_5.sqlite (tokens_used)" ;;
        gemini) pnote="telemetry: N/A (server-side sessions)" ;;
        *)      pnote="" ;;
    esac

    format_line "$pname" "$pver" "$pstate" "$pnote"
done

echo ""

# Passive upgrade notice. The check is throttled to a 24h cache, so calling
# this on every `/tokenwar status` is cheap. Failure here must not break status:
# absorb any error and skip the section.
CHECK_UPDATES_SCRIPT="${SCRIPT_DIR}/check-updates.sh"
readonly CHECK_UPDATES_SCRIPT
if [[ -x "$CHECK_UPDATES_SCRIPT" ]]; then
    update_count="$(
        bash "$CHECK_UPDATES_SCRIPT" --quiet 2>/dev/null
        echo "EXIT=$?"
    )"
    if [[ "$update_count" == *"EXIT=2"* ]]; then
        readonly UPGRADE_CACHE_FILE="${HOME}/.claude/tokenwar/upgrade-check.json"
        if [[ -f "$UPGRADE_CACHE_FILE" ]]; then
            CACHE="$UPGRADE_CACHE_FILE" node --input-type=module -e "
                import { readFileSync } from 'node:fs';
                const d = JSON.parse(readFileSync(process.env.CACHE, 'utf8'));
                const ups = Object.entries(d.tools).filter(([,v]) => v.state === 'update-available');
                console.log(\`  updates available (\${ups.length}):\`);
                for (const [n, v] of ups) {
                    console.log(\`    - \${n.padEnd(14)} \${v.installed} → \${v.latest}\`);
                }
                console.log('');
                console.log('  → Run \`/tokenwar upgrade\` to apply.');
            " 2>/dev/null || true
            echo ""
        fi
    fi
fi

# Exit code: gated ONLY on the 5 managed tools. Providers are optional and never
# fail the exit (an absent codex/gemini on a Claude-only host is not an error).
tool_failures=0
for s in "$ctx_state" "$mem_state" "$cave_state" "$pony_state" "$rtk_st"; do
    [[ "$s" == "$STATUS_OK" ]] || tool_failures=1
done

if (( tool_failures )); then
    exit 1
fi
exit 0
