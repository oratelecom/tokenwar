#!/usr/bin/env bash
# perfia statusline — combined badge for the 4-tool token-saving stack.
# Emits: [ctx vX] [mem vY] [rtk SAVED] [CAVEMAN vZ]
# Each badge: GREEN if active, RED if inactive.
# Stdin: receives Claude Code statusline JSON (ignored).

set -uo pipefail

readonly LOOKUP_TIMEOUT_SECS=1
readonly RTK_BIN="rtk"
readonly CLAUDE_BIN="claude"
readonly SLUG_CTX="context-mode@context-mode"
readonly SLUG_MEM="claude-mem@thedotmack"
readonly SLUG_CAVE="caveman@caveman"
readonly VERSION_HASH_TRIM_LEN=7

readonly COL_GREEN=$'\033[32m'
readonly COL_RED=$'\033[31m'
readonly COL_RESET=$'\033[0m'

# Drain stdin (Claude Code passes session JSON we don't need)
read -r -t "$LOOKUP_TIMEOUT_SECS" _ 2>/dev/null || true

# One plugin list call shared by all plugin lookups
plugin_list_json=$(timeout "$LOOKUP_TIMEOUT_SECS" "$CLAUDE_BIN" plugin list --json 2>/dev/null || echo '[]')

# Returns "version|enabled" e.g. "1.0.107|true". version="-" if not installed.
plugin_lookup() {
    local slug="$1"
    PLUGIN_QUERY="$slug" PLUGIN_LIST_JSON="$plugin_list_json" node --input-type=module -e '
        const arr = JSON.parse(process.env.PLUGIN_LIST_JSON || "[]");
        const e = arr.find(p => p.id === process.env.PLUGIN_QUERY);
        if (!e) { console.log("-|false"); process.exit(0); }
        const v = String(e.version || "?");
        const HASH_RE = /^[0-9a-f]{12,}$/;
        const short = HASH_RE.test(v) ? v.slice(0, '"$VERSION_HASH_TRIM_LEN"') : v;
        console.log(short + "|" + (e.enabled ? "true" : "false"));
    ' 2>/dev/null || echo "-|false"
}

# Render one [label value] badge green if active else red
badge() {
    local label="$1" value="$2" active="$3"
    local color="$COL_RED"
    [[ "$active" == "true" ]] && color="$COL_GREEN"
    printf "%s[%s %s]%s" "$color" "$label" "$value" "$COL_RESET"
}

# === ctx ===
IFS='|' read -r ctx_ver ctx_enabled <<<"$(plugin_lookup "$SLUG_CTX")"

# === mem ===
IFS='|' read -r mem_ver mem_enabled <<<"$(plugin_lookup "$SLUG_MEM")"

# === caveman ===
IFS='|' read -r cave_ver cave_enabled <<<"$(plugin_lookup "$SLUG_CAVE")"

# === rtk === active iff (a) CLI present AND (b) hook wired in settings.json
readonly RTK_SETTINGS_FILE="${HOME}/.claude/settings.json"
rtk_saved="-"
rtk_active="false"
if command -v "$RTK_BIN" >/dev/null 2>&1; then
    rtk_hook_wired=$(SETTINGS="$RTK_SETTINGS_FILE" node --input-type=module -e '
        import { readFileSync } from "fs";
        try {
            const cfg = JSON.parse(readFileSync(process.env.SETTINGS, "utf8"));
            const pre = (cfg.hooks && cfg.hooks.PreToolUse) || [];
            const wired = pre.some(h => (h.matcher||"") === "Bash"
                && (h.hooks||[]).some(x => (x.command||"").includes("rtk-rewrite")));
            console.log(wired ? "true" : "false");
        } catch { console.log("false"); }
    ' 2>/dev/null || echo "false")
    if [[ "$rtk_hook_wired" == "true" ]]; then
        rtk_out=$(timeout "$LOOKUP_TIMEOUT_SECS" "$RTK_BIN" gain 2>/dev/null || true)
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
