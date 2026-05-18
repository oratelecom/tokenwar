#!/usr/bin/env bash
# perfia status — report state of the 4 token-saving tools
#
# Exit 0 if all 4 are healthy, 1 otherwise.
# Pass --test to additionally run a liveness ping for each tool
# (note: context-mode ping requires the ctx_stats MCP tool, which
# shell cannot reach — the caller is responsible for that one).

set -euo pipefail

readonly STATUS_OK="OK"
readonly STATUS_DISABLED="installed-disabled"
readonly STATUS_MISSING="not-installed"
readonly STATUS_UNKNOWN="unknown"

readonly SLUG_CTX="context-mode@context-mode"
readonly SLUG_MEM="claude-mem@thedotmack"
readonly SLUG_CAVE="caveman@caveman"

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

# === report ===
echo "# /perfia status"
echo ""
printf "  %s  %-14s  %-10s  %-22s  %s\n" "·" "tool" "version" "state" "note"
printf "  ─────────────────────────────────────────────────────────────────\n"

ctx_state=$(plugin_state "$SLUG_CTX");   ctx_ver=$(plugin_version "$SLUG_CTX")
mem_state=$(plugin_state "$SLUG_MEM");   mem_ver=$(plugin_version "$SLUG_MEM")
cave_state=$(plugin_state "$SLUG_CAVE"); cave_ver=$(plugin_version "$SLUG_CAVE")
rtk_st=$(rtk_state);                     rtk_ver=$(rtk_version)

ctx_extra=""; mem_extra=""; cave_extra=""; rtk_extra=""
if $test_mode; then
    ctx_extra="ping=via MCP (caller)"
    ping_claude_mem && mem_extra="ping=ok" || mem_extra="ping=FAIL"
    ping_rtk        && rtk_extra="ping=ok" || rtk_extra="ping=FAIL"
    ping_caveman    && cave_extra="ping=ok" || cave_extra="ping=FAIL"
fi

format_line "context-mode" "$ctx_ver"  "$ctx_state"  "$ctx_extra"
format_line "claude-mem"   "$mem_ver"  "$mem_state"  "$mem_extra"
format_line "rtk"          "$rtk_ver"  "$rtk_st"     "$rtk_extra"
format_line "caveman"      "$cave_ver" "$cave_state" "$cave_extra"
echo ""

# Exit code: 0 if all OK, 1 otherwise
for s in "$ctx_state" "$mem_state" "$cave_state" "$rtk_st"; do
    [[ "$s" == "$STATUS_OK" ]] || exit 1
done
exit 0
