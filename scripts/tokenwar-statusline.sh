#!/usr/bin/env bash
# tokenwar statusline — combined badge for the 6-tool token-saving stack.
# Emits: [ctx vX] [mem vY] [rtk SAVED] [caveman vZ] [ponytail on] [pxpipe vX]
# Each badge: GREEN if active, RED if inactive. A yellow ⬆ is appended to any
# tool with an available update (per the check-updates.sh cache), and when at
# least one update exists the bar ends with a "⬆ N updates · /tokenwar upgrade"
# call-to-action.
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
readonly PLUGIN_CACHE="${CACHE_DIR}/tokenwar-plugins-${USER}.json"
readonly RTK_GAIN_CACHE="${CACHE_DIR}/tokenwar-rtk-gain-${USER}.txt"
readonly RTK_BIN="rtk"
readonly PXPIPE_BIN="pxpipe"
readonly CLAUDE_BIN="claude"
readonly SLUG_CTX="context-mode@context-mode"
readonly SLUG_MEM="claude-mem@thedotmack"
readonly SLUG_CAVE="caveman@caveman"

readonly VERSION_HASH_TRIM_LEN=7
readonly SETTINGS_JSON="${HOME}/.claude/settings.json"
readonly SETTINGS_LOCAL_JSON="${HOME}/.claude/settings.local.json"

# ponytail (lazy-dev ruleset): now a real Claude Code plugin with a runtime mode
# toggle. Its SessionStart hook writes ~/.claude/.ponytail-active with the live
# intensity (off mode clears the file). Badge is green with the active mode iff
# the plugin is enabled AND the flag reports a live mode (full renders as a plain
# "on"); red [ponytail off] when disabled or toggled off. Still presence-only —
# no token telemetry, exactly like caveman.
readonly SLUG_PONY="ponytail@ponytail"
readonly PONYTAIL_FLAG="${HOME}/.claude/.ponytail-active"
readonly PONYTAIL_LABEL="ponytail"
readonly PONYTAIL_FULL_MODE="full"
readonly PONYTAIL_ON_VALUE="on"
readonly PONYTAIL_OFF_VALUE="off"

# Portable timeout: GNU coreutils ships `timeout`, BSD/macOS doesn't.
if command -v timeout >/dev/null 2>&1; then
    _TIMEOUT_CMD=timeout
elif command -v gtimeout >/dev/null 2>&1; then
    _TIMEOUT_CMD=gtimeout
else
    _TIMEOUT_CMD=""
fi

# Update badge: read the throttled upgrade-check cache (written by
# check-updates.sh) and append a ⬆ marker to any tool with an available update.
# Read-only at render time; a background refresh is kicked off only when the
# cache is older than UPDATE_CACHE_TTL_SECS, never blocking the bar.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

readonly UPDATE_CACHE="${HOME}/.claude/tokenwar/upgrade-check.json"
readonly UPDATE_CHECK_SCRIPT="${SCRIPT_DIR}/check-updates.sh"
readonly UPDATE_REFRESH_LOCK="${UPDATE_CACHE}.refresh.lock"
readonly UPDATE_CACHE_TTL_SECS=86400      # 24h — match check-updates.sh
readonly UPDATE_REFRESH_LOCK_TTL_SECS=600 # don't re-spawn a refresh within 10m
readonly UPDATE_STATE_AVAILABLE="update-available" # cross-script contract w/ check-updates.sh
readonly UPDATE_MARKER="⬆"
readonly UPDATE_CTA_CMD="/tokenwar upgrade"
readonly UPDATE_WORD_SINGULAR="update"
readonly UPDATE_WORD_PLURAL="updates"
readonly KEY_CTX="context-mode"
readonly KEY_MEM="claude-mem"
readonly KEY_RTK="rtk"
readonly KEY_CAVE="caveman"
readonly KEY_PXPIPE="pxpipe"

readonly COL_GREEN=$'\033[32m'
readonly COL_RED=$'\033[31m'
readonly COL_YELLOW=$'\033[33m'
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
        local age mtime
        # Portable stat: GNU is `-c %Y`, BSD/macOS is `-f %m`.
        mtime=$(stat -c %Y "$cache_file" 2>/dev/null || stat -f %m "$cache_file" 2>/dev/null || echo 0)
        age=$(( $(date +%s) - mtime ))
        if (( age < ttl )); then
            cat "$cache_file"
            return 0
        fi
    fi
    local fresh
    if [[ -n "$_TIMEOUT_CMD" ]]; then
        fresh=$("$_TIMEOUT_CMD" "$timeout_secs" "$@" 2>/dev/null)
    else
        fresh=$("$@" 2>/dev/null)
    fi
    if [[ -n "$fresh" ]]; then
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

# Kick a background refresh of the upgrade-check cache when it's stale, guarded
# by a short-lived lock so concurrent renders don't spawn a storm. Detached —
# the render never waits on it.
maybe_refresh_updates() {
    local now cache_age lock_age
    now=$(date +%s)
    if [[ -f "$UPDATE_CACHE" ]]; then
        cache_age=$(( now - $(stat -c %Y "$UPDATE_CACHE" 2>/dev/null || echo 0) ))
        (( cache_age < UPDATE_CACHE_TTL_SECS )) && return 0
    fi
    if [[ -f "$UPDATE_REFRESH_LOCK" ]]; then
        lock_age=$(( now - $(stat -c %Y "$UPDATE_REFRESH_LOCK" 2>/dev/null || echo 0) ))
        (( lock_age < UPDATE_REFRESH_LOCK_TTL_SECS )) && return 0
    fi
    [[ -f "$UPDATE_CHECK_SCRIPT" ]] || return 0
    : > "$UPDATE_REFRESH_LOCK" 2>/dev/null || true
    ( nohup bash "$UPDATE_CHECK_SCRIPT" --quiet --force >/dev/null 2>&1; rm -f "$UPDATE_REFRESH_LOCK" ) >/dev/null 2>&1 &
    disown 2>/dev/null || true
}

# Echo "ctx|mem|rtk|caveman|pxpipe", each "true"/"false" for update-available, from the
# cache only (no network). Missing/corrupt cache → all "false".
update_states() {
    UPD_CACHE="$UPDATE_CACHE" STATE_AVAIL="$UPDATE_STATE_AVAILABLE" \
    K_CTX="$KEY_CTX" K_MEM="$KEY_MEM" K_RTK="$KEY_RTK" K_CAVE="$KEY_CAVE" K_PXPIPE="$KEY_PXPIPE" \
    node --input-type=module -e '
        import { readFileSync } from "fs";
        let tools = {};
        try { tools = (JSON.parse(readFileSync(process.env.UPD_CACHE, "utf8")).tools) || {}; } catch {}
        const up = (k) => (tools[k] && tools[k].state === process.env.STATE_AVAIL) ? "true" : "false";
        console.log([up(process.env.K_CTX), up(process.env.K_MEM), up(process.env.K_RTK), up(process.env.K_CAVE), up(process.env.K_PXPIPE)].join("|"));
    ' 2>/dev/null || echo "false|false|false|false|false"
}

maybe_refresh_updates
IFS='|' read -r ctx_upd mem_upd rtk_upd cave_upd pxpipe_upd <<<"$(update_states)"

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
    local label="$1" value="$2" active="$3" update="${4:-false}"
    local color="$COL_RED"
    [[ "$active" == "true" ]] && color="$COL_GREEN"
    local marker=""
    [[ "$update" == "true" ]] && marker=" ${COL_YELLOW}${UPDATE_MARKER}${color}"
    printf "%s[%s %s%s]%s" "$color" "$label" "$value" "$marker" "$COL_RESET"
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

# pxpipe: CLI presence/version. The proxy is started on demand by the user or
# provider wrapper, so the badge reports availability rather than daemon state.
pxpipe_ver="-"
pxpipe_active="false"
if command -v "$PXPIPE_BIN" >/dev/null 2>&1; then
    pxpipe_ver=$("$PXPIPE_BIN" --version 2>/dev/null | head -1 | sed 's/^[^0-9]*//' | awk '{print $1}')
    pxpipe_ver="${pxpipe_ver:--}"
    pxpipe_active="true"
fi

# ponytail: real runtime state from the plugin. Green with the active intensity
# iff the plugin is enabled AND the flag reports a live mode (full renders as a
# plain "on"); red "off" when the plugin is disabled or toggled off.
IFS='|' read -r _pony_ver pony_enabled <<<"$(plugin_lookup "$SLUG_PONY")"
ponytail_active="false"
ponytail_val="$PONYTAIL_OFF_VALUE"
if [[ "$pony_enabled" == "true" && -f "$PONYTAIL_FLAG" ]]; then
    pony_mode=$(head -n1 "$PONYTAIL_FLAG" | tr -d '[:space:]')
    if [[ -n "$pony_mode" ]]; then
        ponytail_active="true"
        if [[ "$pony_mode" == "$PONYTAIL_FULL_MODE" ]]; then
            ponytail_val="$PONYTAIL_ON_VALUE"
        else
            ponytail_val="$pony_mode"
        fi
    fi
fi

# Aggregate call-to-action: when ≥1 tool has an update, append a single hint
# pointing at the upgrade command. Clean bar (no suffix) when all up-to-date.
update_count=0
for u in "$ctx_upd" "$mem_upd" "$rtk_upd" "$cave_upd" "$pxpipe_upd"; do
    [[ "$u" == "true" ]] && update_count=$((update_count + 1))
done
summary=""
if (( update_count > 0 )); then
    word="$UPDATE_WORD_PLURAL"
    (( update_count == 1 )) && word="$UPDATE_WORD_SINGULAR"
    summary=$(printf "  %s%s %d %s · %s%s" \
        "$COL_YELLOW" "$UPDATE_MARKER" "$update_count" "$word" "$UPDATE_CTA_CMD" "$COL_RESET")
fi

printf "%s %s %s %s %s %s%s" \
    "$(badge ctx               "$ctx_ver"      "$ctx_enabled"   "$ctx_upd")" \
    "$(badge mem               "$mem_ver"      "$mem_enabled"   "$mem_upd")" \
    "$(badge rtk               "$rtk_saved"    "$rtk_active"    "$rtk_upd")" \
    "$(badge caveman           "$cave_ver"     "$cave_enabled"  "$cave_upd")" \
    "$(badge "$PONYTAIL_LABEL" "$ponytail_val" "$ponytail_active" "false")" \
    "$(badge pxpipe            "$pxpipe_ver"   "$pxpipe_active" "$pxpipe_upd")" \
    "$summary"
