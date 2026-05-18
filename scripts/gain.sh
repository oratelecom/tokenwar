#!/usr/bin/env bash
# perfia gain — aggregate per-tool + global token savings
#
# RTK and context-mode have native telemetry. claude-mem and caveman
# rely on the optional perfia-gain-hook.sh that logs to
# ~/.claude/perfia/gain.jsonl. If that file does not exist, those
# two tools report N/A rather than 0 — we never fabricate numbers.
#
# context-mode itself requires an MCP call (`ctx_stats`) that shell
# cannot perform. The caller must inject CTX_STATS_JSON in the env
# (set to the JSON returned by ctx_stats). If absent, we report N/A
# for context-mode and surface the gap.

set -euo pipefail

readonly GAIN_LOG="${HOME}/.claude/perfia/gain.jsonl"
readonly CHARS_PER_TOKEN=4
readonly RTK_BIN="rtk"

readonly COL_BOLD=$'\033[1m'
readonly COL_DIM=$'\033[2m'
readonly COL_RESET=$'\033[0m'

# === RTK ===
# Returns: human-readable saved | note | numeric tokens saved
rtk_summary() {
    if ! command -v "$RTK_BIN" >/dev/null 2>&1; then
        echo "N/A|RTK not installed|0"; return
    fi
    local out
    out="$("$RTK_BIN" gain 2>/dev/null || true)"
    if [[ -z "$out" ]]; then
        echo "N/A|rtk gain returned nothing|0"; return
    fi
    # Parse lines like:  Tokens saved:      44.7M (68.3%)
    #                    Total commands:    18956
    local saved_human pct count saved_num
    saved_human=$(echo "$out" | awk '/Tokens saved:/ {print $3; exit}')
    pct=$(echo "$out"         | awk -F'[()%]' '/Tokens saved:/ {print $2; exit}')
    count=$(echo "$out"       | awk '/Total commands:/ {print $3; exit}')
    saved_human="${saved_human:-?}"; pct="${pct:-?}"; count="${count:-?}"
    # Convert human suffix (M/K/G) to integer
    saved_num=$(echo "$saved_human" | awk '
        /M$/ { gsub(/M$/,""); printf "%.0f", $1 * 1e6; exit }
        /K$/ { gsub(/K$/,""); printf "%.0f", $1 * 1e3; exit }
        /G$/ { gsub(/G$/,""); printf "%.0f", $1 * 1e9; exit }
        { printf "%.0f", $1+0; exit }
    ')
    saved_num="${saved_num:-0}"
    echo "${saved_human}|${count} commands (${pct}%)|${saved_num}"
}

# === context-mode ===
# Expects $CTX_STATS_JSON to be set by the caller (Claude runs ctx_stats first).
ctx_summary() {
    if [[ -z "${CTX_STATS_JSON:-}" ]]; then
        echo "N/A|ctx_stats not provided by caller — pass via env CTX_STATS_JSON|0"; return
    fi
    node --input-type=module -e "
        const j = JSON.parse(process.env.CTX_STATS_JSON);
        const kb = j.total_size_kb || j.totalSizeKb || j.size_kb || 0;
        const entries = j.entry_count || j.entries || j.count || 0;
        const tokens = Math.round((kb * 1024) / $CHARS_PER_TOKEN);
        const human = tokens >= 1e6 ? (tokens/1e6).toFixed(1)+'M' :
                       tokens >= 1e3 ? (tokens/1e3).toFixed(1)+'K' : String(tokens);
        console.log(human + '|' + entries + ' entries indexed|' + tokens);
    " 2>/dev/null || echo "N/A|ctx_stats JSON parse failed|0"
}

# === claude-mem / caveman from the perfia gain log ===
jsonl_summary_for_tool() {
    local tool="$1"
    if [[ ! -f "$GAIN_LOG" ]]; then
        echo "N/A|gain hook not installed (see /perfia activate)|0"; return
    fi
    node --input-type=module -e "
        import { readFileSync } from 'fs';
        const lines = readFileSync('$GAIN_LOG','utf8').split('\n').filter(Boolean);
        let saved_bytes = 0, count = 0;
        for (const ln of lines) {
            let r; try { r = JSON.parse(ln); } catch { continue; }
            if (r.tool !== '$tool') continue;
            const before = Number(r.bytes_in)  || 0;
            const after  = Number(r.bytes_out) || 0;
            if (before > after) saved_bytes += (before - after);
            count++;
        }
        if (count === 0) { console.log('N/A|no entries logged yet|0'); process.exit(0); }
        const tokens = Math.round(saved_bytes / $CHARS_PER_TOKEN);
        const human = tokens >= 1e6 ? (tokens/1e6).toFixed(1)+'M' :
                       tokens >= 1e3 ? (tokens/1e3).toFixed(1)+'K' : String(tokens);
        console.log(human + '|' + count + ' compressions|' + tokens);
    " 2>/dev/null || echo "N/A|gain.jsonl parse failed|0"
}

# === render ===
echo ""
echo "${COL_BOLD}# /perfia gain — token savings${COL_RESET}"
echo ""
printf "  %-14s  %-10s  %s\n" "tool" "saved" "note"
echo   "  ─────────────────────────────────────────────────────────────"

total=0
for entry in \
    "RTK|$(rtk_summary)" \
    "context-mode|$(ctx_summary)" \
    "claude-mem|$(jsonl_summary_for_tool claude-mem)" \
    "caveman|$(jsonl_summary_for_tool caveman)"; do
    tool="${entry%%|*}"
    summary="${entry#*|}"
    saved=""; note=""; tokens=""
    IFS='|' read -r saved note tokens <<<"$summary"
    printf "  %-14s  %-10s  %s\n" "$tool" "$saved" "${COL_DIM}${note}${COL_RESET}"
    total=$((total + ${tokens:-0}))
done

echo   "  ─────────────────────────────────────────────────────────────"
if (( total >= 1000000 )); then
    human="$(awk -v t="$total" 'BEGIN{printf "%.1fM", t/1000000}')"
elif (( total >= 1000 )); then
    human="$(awk -v t="$total" 'BEGIN{printf "%.1fK", t/1000}')"
else
    human="$total"
fi
printf "  %-14s  %-10s  %s\n" "TOTAL" "$human" "summed across tools with telemetry"
echo ""
echo "(Next: run /perfia check to verify the gain is real and not double-counted.)"
