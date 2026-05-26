#!/usr/bin/env bash
# perfia statusline — combined badge for the 4-tool token-saving stack.
# Emits: [ctx vX] [mem vY] [rtk SAVED] [caveman vZ]
# Each badge: GREEN if active, RED if inactive.
# Stdin: receives Claude Code statusline JSON (ignored).
#
# Cache strategy: `claude plugin list --json` and `rtk gain` are spawned at
# most once per CACHE_TTL_SECS. Atomic write via mktemp+mv. On spawn
# timeout/failure, fall back to stale cache so a cold CC daemon never paints
# the bar red.

set -uo pipefail

readonly LOOKUP_TIMEOUT_SECS=1
readonly CACHE_TTL_SECS=30
readonly CACHE_DIR="${TMPDIR:-/tmp}"
readonly PLUGIN_CACHE="${CACHE_DIR}/perfia-plugins-${USER}.json"
readonly RTK_GAIN_CACHE="${CACHE_DIR}/perfia-rtk-gain-${USER}.txt"
readonly RTK_BIN="rtk"
readonly CLAUDE_BIN="claude"
readonly SLUG_CTX="context-mode@context-mode"
readonly SLUG_MEM="claude-mem@thedotmack"
readonly SLUG_CAVE="caveman@caveman"
readonly VERSION_HASH_TRIM_LEN=7
readonly SETTINGS_JSON="${HOME}/.claude/settings.json"
readonly SETTINGS_LOCAL_JSON="${HOME}/.claude/settings.local.json"

readonly COL_GREEN=$'\033[32m'
readonly COL_RED=$'\033[31m'
readonly COL_RESET=$'\033[0m'

# Drain stdin (Claude Code passes session JSON we don't need)
read -r -t "$LOOKUP_TIMEOUT_SECS" _ 2>/dev/null || true

# cache_or_run <cache_file> <ttl_secs> <timeout_secs> <cmd...>
# Fast path: cache hit within TTL → echo cached content, no spawn.
# Slow path: spawn cmd with timeout, atomically write cache, echo fresh.
# Degraded: spawn failed/empty → echo stale cache if any, else "".
cache_or_run() {
    local cache_file="$1" ttl="$2" timeout_secs="$3"
    shift 3
    if [[ -f "$cache_file" ]]; then
        local age
        age=$(( $(date +%s) - $(stat -c %Y "$cache_file") ))
        if (( age < ttl )); then
            cat "$cache_file"
            return 0
        fi
    fi
    local fresh
    if fresh=$(timeout "$timeout_secs" "$@" 2>/dev/null) && [[ -n "$fresh" ]]; then
        local tmp
        if tmp=$(mktemp "${cache_file}.XXXXXX" 2>/dev/null); then
            printf '%s' "$fresh" > "$tmp"
            mv -f "$tmp" "$cache_file"
        fi
        printf '%s' "$fresh"
        return 0
    fi
    # Degraded: fall back to stale cache rather than empty result
    if [[ -f "$cache_file" ]]; then
        cat "$cache_file"
    fi
}

plugin_list_json=$(cache_or_run "$PLUGIN_CACHE" "$CACHE_TTL_SECS" "$LOOKUP_TIMEOUT_SECS" "$CLAUDE_BIN" plugin list --json)
plugin_list_json="${plugin_list_json:-[]}"

# Read enabledPlugins from BOTH settings files and OR-merge.
# CC's `plugin list` only reads settings.json — but CC actually merges both
# at runtime, so a wipe of settings.json's enabledPlugins shouldn't paint
# a still-loaded plugin red.
enabled_plugins_json=$(SETTINGS="$SETTINGS_JSON" SETTINGS_LOCAL="$SETTINGS_LOCAL_JSON" node --input-type=module -e '
    import { readFileSync } from "fs";
    const read = (p) => { try { return JSON.parse(readFileSync(p,"utf8")).enabledPlugins || {}; } catch { return {}; } };
    const merged = { ...read(process.env.SETTINGS), ...read(process.env.SETTINGS_LOCAL) };
    const out = {};
    for (const [k,v] of Object.entries(merged)) if (v) out[k] = true;
    console.log(JSON.stringify(out));
' 2>/dev/null || echo "{}")

# Returns "version|enabled" e.g. "1.0.107|true". version="-" if not installed.
plugin_lookup() {
    local slug="$1"
    PLUGIN_QUERY="$slug" PLUGIN_LIST_JSON="$plugin_list_json" ENABLED_JSON="$enabled_plugins_json" node --input-type=module -e '
        const arr = JSON.parse(process.env.PLUGIN_LIST_JSON || "[]");
        const enabled = JSON.parse(process.env.ENABLED_JSON || "{}");
        const slug = process.env.PLUGIN_QUERY;
        const e = arr.find(p => p.id === slug);
        if (!e) { console.log("-|false"); process.exit(0); }
        const v = String(e.version || "?");
        const HASH_RE = /^[0-9a-f]{12,}$/;
        const short = HASH_RE.test(v) ? v.slice(0, '"$VERSION_HASH_TRIM_LEN"') : v;
        const isEnabled = e.enabled || enabled[slug] === true;
        console.log(short + "|" + (isEnabled ? "true" : "false"));
    ' 2>/dev/null || echo "-|false"
}

badge() {
    local label="$1" value="$2" active="$3"
    local color="$COL_RED"
    [[ "$active" == "true" ]] && color="$COL_GREEN"
    printf "%s[%s %s]%s" "$color" "$label" "$value" "$COL_RESET"
}

IFS='|' read -r ctx_ver ctx_enabled <<<"$(plugin_lookup "$SLUG_CTX")"
IFS='|' read -r mem_ver mem_enabled <<<"$(plugin_lookup "$SLUG_MEM")"
IFS='|' read -r cave_ver cave_enabled <<<"$(plugin_lookup "$SLUG_CAVE")"

# rtk: CLI present AND hook wired in settings.json OR settings.local.json
rtk_saved="-"
rtk_active="false"
if command -v "$RTK_BIN" >/dev/null 2>&1; then
    rtk_hook_wired=$(SETTINGS="$SETTINGS_JSON" SETTINGS_LOCAL="$SETTINGS_LOCAL_JSON" node --input-type=module -e '
        import { readFileSync } from "fs";
        const wiredIn = (path) => {
            try {
                const cfg = JSON.parse(readFileSync(path, "utf8"));
                const pre = (cfg.hooks && cfg.hooks.PreToolUse) || [];
                return pre.some(h => (h.matcher||"") === "Bash"
                    && (h.hooks||[]).some(x => (x.command||"").includes("rtk-rewrite")));
            } catch { return false; }
        };
        const wired = wiredIn(process.env.SETTINGS) || wiredIn(process.env.SETTINGS_LOCAL);
        console.log(wired ? "true" : "false");
    ' 2>/dev/null || echo "false")
    if [[ "$rtk_hook_wired" == "true" ]]; then
        rtk_out=$(cache_or_run "$RTK_GAIN_CACHE" "$CACHE_TTL_SECS" "$LOOKUP_TIMEOUT_SECS" "$RTK_BIN" gain)
        rtk_saved=$(echo "$rtk_out" | awk '/Tokens saved:/ {print $3; exit}')
        rtk_saved="${rtk_saved:--}"
        rtk_active="true"
    fi
fi

printf "%s %s %s %s" \
    "$(badge ctx     "$ctx_ver"  "$ctx_enabled")" \
    "$(badge mem     "$mem_ver"  "$mem_enabled")" \
    "$(badge rtk     "$rtk_saved" "$rtk_active")" \
    "$(badge caveman "$cave_ver" "$cave_enabled")"
