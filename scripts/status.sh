#!/usr/bin/env bash
# tokenwar status — report state of the 7 token-saving tools + AI providers.
#
# Exit 0 if all 7 tools are healthy, 1 otherwise. Providers are
# OPTIONAL — they are reported for information but their absence never fails the
# exit code (a Claude-only host has no other provider CLIs and must still exit 0).
# Pass --test to additionally run a liveness ping for each tool
# (note: context-mode ping requires the ctx_stats MCP tool, which
# shell cannot reach — the caller is responsible for that one).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# shellcheck source=lib/providers.sh
source "${SCRIPT_DIR}/lib/providers.sh"
# shellcheck source=lib/plugins.sh
source "${SCRIPT_DIR}/lib/plugins.sh"

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
readonly PXPIPE_BIN="pxpipe"
readonly GRAPHIFY_BIN="graphify"

# graphify ships as a PyPI package (`graphifyy`) whose CLI is `graphify`, plus a
# per-assistant skill that `graphify install` copies into the assistant's config
# dir. Both halves matter: the CLI alone builds graphs nobody's agent knows to
# query. CLAUDE_CONFIG_DIR keeps this testable and honours a relocated ~/.claude.
readonly GRAPHIFY_CLAUDE_SKILL="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/skills/graphify/SKILL.md"

# Cache the plugin list. CLI-first with on-disk fallback lives in lib/plugins.sh
# (tw_load_plugin_list) so every script that needs plugin state shares one path.
PLUGIN_LIST_JSON=""
load_plugin_list() {
    [[ -n "$PLUGIN_LIST_JSON" ]] && return
    PLUGIN_LIST_JSON="$(TW_CLAUDE_BIN="$CLAUDE_BIN" tw_load_plugin_list)"
}

readonly COL_GREEN=$'\033[32m'
readonly COL_RED=$'\033[31m'
readonly COL_YELLOW=$'\033[33m'
readonly COL_RESET=$'\033[0m'

test_mode=false
json_mode=false
for arg in "$@"; do
    case "$arg" in
        --test) test_mode=true ;;
        --json) json_mode=true ;;
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

pxpipe_state() {
    if ! command -v "$PXPIPE_BIN" >/dev/null 2>&1; then
        echo "$STATUS_MISSING"; return
    fi
    echo "$STATUS_OK"
}

pxpipe_version() {
    if ! command -v "$PXPIPE_BIN" >/dev/null 2>&1; then echo "-"; return; fi
    "$PXPIPE_BIN" --version 2>/dev/null | head -1 | sed 's/^[^0-9]*//' | awk '{print $1}'
}

# graphify: CLI on PATH + the skill registered with the assistant. A CLI without
# a registered skill is "installed-disabled" — the graph can be built by hand but
# the agent never reaches for it, which is the whole point of the tool.
graphify_state() {
    if ! command -v "$GRAPHIFY_BIN" >/dev/null 2>&1; then
        echo "$STATUS_MISSING"; return
    fi
    if [[ ! -f "$GRAPHIFY_CLAUDE_SKILL" ]]; then
        echo "$STATUS_DISABLED"; return
    fi
    echo "$STATUS_OK"
}

graphify_version() {
    if ! command -v "$GRAPHIFY_BIN" >/dev/null 2>&1; then echo "-"; return; fi
    "$GRAPHIFY_BIN" --version 2>/dev/null | head -1 | sed 's/^[^0-9]*//' | awk '{print $1}'
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
ping_pxpipe() {
    "$PXPIPE_BIN" --version >/dev/null 2>&1
}
ping_caveman() {
    # caveman is a hook + skill, no CLI ping. Verify on-disk artifacts.
    local cache_root="${HOME}/.claude/plugins/cache/caveman/caveman"
    [[ -d "$cache_root" ]] && find "$cache_root" -mindepth 2 -maxdepth 4 -type d -name skills 2>/dev/null | grep -q .
}
ping_graphify() {
    # graphify is a CLI + skill, no daemon. `--version` is the cheapest call that
    # proves the Python entrypoint resolves (the common failure is a broken
    # interpreter path after a pip/uv reinstall, which --version catches).
    "$GRAPHIFY_BIN" --version >/dev/null 2>&1
}
ping_ponytail() {
    # ponytail is a mode-gated plugin, no CLI ping. Alive iff installed + enabled.
    [[ "$(plugin_state "$SLUG_PONY")" == "$STATUS_OK" ]]
}

# === data gathering (shared by text and json modes) ===
ctx_state=$(plugin_state "$SLUG_CTX");   ctx_ver=$(plugin_version "$SLUG_CTX")
mem_state=$(plugin_state "$SLUG_MEM");   mem_ver=$(plugin_version "$SLUG_MEM")
cave_state=$(plugin_state "$SLUG_CAVE"); cave_ver=$(plugin_version "$SLUG_CAVE")
pony_state=$(plugin_state "$SLUG_PONY"); pony_ver=$(plugin_version "$SLUG_PONY")
rtk_st=$(rtk_state);                     rtk_ver=$(rtk_version)
pxpipe_st=$(pxpipe_state);               pxpipe_ver=$(pxpipe_version)
graphify_st=$(graphify_state);           graphify_ver=$(graphify_version)

ctx_extra=""; mem_extra=""; cave_extra=""; pony_extra=""; rtk_extra=""; pxpipe_extra=""
graphify_extra=""
if $test_mode; then
    ctx_extra="ping=via MCP (caller)"
    ping_claude_mem && mem_extra="ping=ok" || mem_extra="ping=FAIL"
    ping_rtk        && rtk_extra="ping=ok" || rtk_extra="ping=FAIL"
    ping_pxpipe     && pxpipe_extra="ping=ok" || pxpipe_extra="ping=FAIL"
    ping_caveman    && cave_extra="ping=ok" || cave_extra="ping=FAIL"
    ping_ponytail   && pony_extra="ping=ok" || pony_extra="ping=FAIL"
    ping_graphify   && graphify_extra="ping=ok" || graphify_extra="ping=FAIL"
fi

# ── JSON mode ──────────────────────────────────────────────────────
if $json_mode; then
    # Gather provider data for JSON
    provider_json_entries=""
    for i in $(seq 0 $((PROVIDER_COUNT - 1))); do
        pid=$(provider_id "$i")
        pname=$(provider_name "$i")
        pver=$(provider_version "$i")
        pstate=$(provider_state_str "$i")
        case "$pid" in
            claude) pnote="telemetry: RTK + ctx_stats + chroma-sync-state" ;;
            codex)  pnote="telemetry: ~/.codex/state_5.sqlite (tokens_used)" ;;
            gemini) pnote="telemetry: N/A (server-side sessions)" ;;
            kimi)   pnote="telemetry: N/A (~/.kimi-code has no token store)" ;;
            opencode) pnote="telemetry: ~/.local/share/opencode/opencode.db (session tokens)" ;;
            *)      pnote="" ;;
        esac
        # Build JSON entry via node to ensure proper escaping
        entry=$(PID="$pid" PNAME="$pname" PVER="$pver" PSTATE="$pstate" PNOTE="$pnote" node --input-type=module -e '
            const e = {
                id: process.env.PID,
                name: process.env.PNAME,
                version: process.env.PVER,
                state: process.env.PSTATE,
                note: process.env.PNOTE
            };
            console.log(JSON.stringify(e));
        ')
        if [[ -z "$provider_json_entries" ]]; then
            provider_json_entries="$entry"
        else
            provider_json_entries="$provider_json_entries,$entry"
        fi
    done

    # Determine overall ok (same logic as exit code)
    tool_failures_json=0
    for s in "$ctx_state" "$mem_state" "$cave_state" "$pony_state" "$rtk_st" "$pxpipe_st" "$graphify_st"; do
        [[ "$s" == "$STATUS_OK" ]] || tool_failures_json=1
    done
    ok_json=$([[ $tool_failures_json -eq 0 ]] && echo "true" || echo "false")

    CTX_STATE="$ctx_state" CTX_VER="$ctx_ver" CTX_EXTRA="$ctx_extra" \
    MEM_STATE="$mem_state" MEM_VER="$mem_ver" MEM_EXTRA="$mem_extra" \
    RTK_STATE="$rtk_st" RTK_VER="$rtk_ver" RTK_EXTRA="$rtk_extra" \
    CAVE_STATE="$cave_state" CAVE_VER="$cave_ver" CAVE_EXTRA="$cave_extra" \
    PONY_STATE="$pony_state" PONY_VER="$pony_ver" PONY_EXTRA="$pony_extra" \
    PXPIPE_STATE="$pxpipe_st" PXPIPE_VER="$pxpipe_ver" PXPIPE_EXTRA="$pxpipe_extra" \
    GRAPHIFY_STATE="$graphify_st" GRAPHIFY_VER="$graphify_ver" GRAPHIFY_EXTRA="$graphify_extra" \
    PROVIDER_ENTRIES="[$provider_json_entries]" OK_JSON="$ok_json" \
    node --input-type=module -e '
        const providers = JSON.parse(process.env.PROVIDER_ENTRIES);
        const providersById = {};
        for (const p of providers) providersById[p.id] = p;
        const tools = {
            "context-mode": { version: process.env.CTX_VER, state: process.env.CTX_STATE, note: process.env.CTX_EXTRA },
            "claude-mem":   { version: process.env.MEM_VER, state: process.env.MEM_STATE, note: process.env.MEM_EXTRA },
            "rtk":          { version: process.env.RTK_VER, state: process.env.RTK_STATE, note: process.env.RTK_EXTRA },
            "caveman":      { version: process.env.CAVE_VER, state: process.env.CAVE_STATE, note: process.env.CAVE_EXTRA },
            "ponytail":     { version: process.env.PONY_VER, state: process.env.PONY_STATE, note: process.env.PONY_EXTRA },
            "pxpipe":       { version: process.env.PXPIPE_VER, state: process.env.PXPIPE_STATE, note: process.env.PXPIPE_EXTRA },
            "graphify":     { version: process.env.GRAPHIFY_VER, state: process.env.GRAPHIFY_STATE, note: process.env.GRAPHIFY_EXTRA }
        };
        const out = {
            tools,
            providers: providersById,
            ok: process.env.OK_JSON === "true"
        };
        console.log(JSON.stringify(out, null, 2));
    '
    # Exit with same code as text mode
    if (( tool_failures_json )); then
        exit 1
    fi
    exit 0
fi

# === report (text mode) ===
echo "# /tokenwar status"
echo ""

# ── Tools ──────────────────────────────────────────────────────────
printf "  %s  %-14s  %-10s  %-22s  %s\n" "·" "tool" "version" "state" "note"
printf "  ─────────────────────────────────────────────────────────────────\n"

format_line "context-mode" "$ctx_ver"  "$ctx_state"  "$ctx_extra"
format_line "claude-mem"   "$mem_ver"  "$mem_state"  "$mem_extra"
format_line "rtk"          "$rtk_ver"  "$rtk_st"     "$rtk_extra"
format_line "caveman"      "$cave_ver" "$cave_state" "$cave_extra"
format_line "ponytail"     "$pony_ver" "$pony_state" "$pony_extra"
format_line "pxpipe"       "$pxpipe_ver" "$pxpipe_st" "$pxpipe_extra"
format_line "graphify"     "$graphify_ver" "$graphify_st" "$graphify_extra"

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
        kimi)   pnote="telemetry: N/A (~/.kimi-code has no token store)" ;;
        opencode) pnote="telemetry: ~/.local/share/opencode/opencode.db (session tokens)" ;;
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
                if (ups.length === 0) process.exit(0);
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

# Exit code: gated ONLY on the 7 managed tools. Providers are optional and never
# fail the exit (absent provider CLIs on a Claude-only host are not an error).
tool_failures=0
for s in "$ctx_state" "$mem_state" "$cave_state" "$pony_state" "$rtk_st" "$pxpipe_st" "$graphify_st"; do
    [[ "$s" == "$STATUS_OK" ]] || tool_failures=1
done

if (( tool_failures )); then
    exit 1
fi
exit 0
