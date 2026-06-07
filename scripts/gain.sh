#!/usr/bin/env bash
# tokenwar gain — aggregate per-tool + global token savings
#
# Each tool is read from its OWN native telemetry — we never fabricate:
#   RTK          — `rtk gain` (+ `rtk gain --monthly` for the $ breakdown)
#   context-mode — `ctx_stats` MCP tool; shell can't call MCP, so the caller
#                  injects its JSON via CTX_STATS_JSON. Absent → N/A.
#   claude-mem   — its chroma-sync-state.json (real stored-memory counts).
#   caveman      — a SessionStart style nudge with no buffer transform, hence
#                  no measurable byte delta → honest N/A (no telemetry surface).

set -euo pipefail

readonly CHARS_PER_TOKEN=4
readonly RTK_BIN="rtk"

# claude-mem native telemetry: its chroma-sync-state.json holds real per-project
# counts of stored observations/summaries (the compact memory it injects on
# resume instead of re-reading full transcripts). Counts are real; the
# tokens-per-item multiplier is a conservative estimate (memory items are short
# — typically a sentence or two), surfaced as "~est" and never as hard truth.
readonly MEM_SYNC_STATE="${HOME}/.claude-mem/chroma-sync-state.json"
readonly MEM_EST_TOKENS_PER_ITEM=40

# Financial valuation of saved tokens. Saved tokens are input-side (context that
# never entered the model), so we value them at each provider's INPUT price per
# 1M tokens. The $ figure is the API-equivalent value of the savings — what the
# same tokens would have cost at list price — not a subscription invoice.
# Claude Opus 4.8 list price (per claude-api skill, cached 2026-05-26).
readonly CLAUDE_INPUT_USD_PER_MTOK="5.00"
readonly CLAUDE_OUTPUT_USD_PER_MTOK="25.00"   # reference only; savings are input-side
readonly CLAUDE_LABEL="Claude Opus 4.8"
# OpenAI Codex (gpt-5-codex) input list price — VERIFY at openai.com/pricing and
# adjust; placeholder as of 2026-06.
readonly CODEX_INPUT_USD_PER_MTOK="1.25"
readonly CODEX_OUTPUT_USD_PER_MTOK="10.00"    # reference only
readonly CODEX_LABEL="Codex (gpt-5-codex)"
readonly MONTH_ROW_RE='^[0-9]{4}-[0-9]{2}[[:space:]]'

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

# === claude-mem from its native chroma-sync-state.json ===
# Real counts (observations + summaries across all projects); tokens estimated.
mem_summary() {
    if [[ ! -f "$MEM_SYNC_STATE" ]]; then
        echo "N/A|claude-mem store not found ($MEM_SYNC_STATE)|0"; return
    fi
    MEM_STATE="$MEM_SYNC_STATE" PER_ITEM="$MEM_EST_TOKENS_PER_ITEM" \
    node --input-type=module -e "
        import { readFileSync } from 'fs';
        let j; try { j = JSON.parse(readFileSync(process.env.MEM_STATE,'utf8')); } catch { console.log('N/A|claude-mem state parse failed|0'); process.exit(0); }
        let obs=0, sum=0, projects=0;
        for (const k of Object.keys(j)) {
            const v = j[k]; if (!v || typeof v !== 'object') continue;
            obs += v.observations||0; sum += v.summaries||0; projects++;
        }
        const items = obs + sum;
        if (items === 0) { console.log('N/A|no memories stored yet|0'); process.exit(0); }
        const tokens = items * Number(process.env.PER_ITEM);
        const human = tokens>=1e6 ? (tokens/1e6).toFixed(1)+'M' : tokens>=1e3 ? (tokens/1e3).toFixed(1)+'K' : String(tokens);
        console.log(human + '|~est: ' + obs + ' obs + ' + sum + ' summaries across ' + projects + ' projects|' + tokens);
    " 2>/dev/null || echo "N/A|claude-mem state read failed|0"
}

# === caveman ===
# caveman is a SessionStart prompt-style nudge ("write terse"); it transforms no
# buffer, so there is no before/after byte delta to measure. Honest N/A — we do
# not invent a number for a tool with no telemetry surface.
caveman_summary() {
    echo "N/A|style-only hook — no measurable buffer (no native telemetry)|0"
}

# === render ===
echo ""
echo "${COL_BOLD}# /tokenwar gain — token savings${COL_RESET}"
echo ""
printf "  %-14s  %-10s  %s\n" "tool" "saved" "note"
echo   "  ─────────────────────────────────────────────────────────────"

total=0
for entry in \
    "RTK|$(rtk_summary)" \
    "context-mode|$(ctx_summary)" \
    "claude-mem|$(mem_summary)" \
    "caveman|$(caveman_summary)"; do
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

# === monthly $ value (RTK is the only timestamped source) ===
# Only RTK has timestamped history: claude-mem's chroma store is a current
# snapshot, context-mode reports a single total, caveman has no telemetry.
# RTK's history.db drives `rtk gain --monthly`, giving a real per-month
# breakdown — we value each month's saved tokens at both providers' input rates.
rtk_monthly_raw=""
if command -v "$RTK_BIN" >/dev/null 2>&1; then
    rtk_monthly_raw="$("$RTK_BIN" gain --monthly 2>/dev/null || true)"
fi
if [[ -n "$rtk_monthly_raw" ]] && grep -qE "$MONTH_ROW_RE" <<<"$rtk_monthly_raw"; then
    echo ""
    echo "${COL_BOLD}Monthly value — API-equivalent \$ saved (RTK)${COL_RESET}"
    printf "  ${COL_DIM}saved tokens × input list price · %s \$%s/M · %s \$%s/M${COL_RESET}\n" \
        "$CLAUDE_LABEL" "$CLAUDE_INPUT_USD_PER_MTOK" "$CODEX_LABEL" "$CODEX_INPUT_USD_PER_MTOK"
    printf "  %-9s  %-10s  %-12s  %s\n" "month" "saved" "claude \$" "codex \$"
    echo   "  ─────────────────────────────────────────────────────────────"
    RTK_MONTHLY="$rtk_monthly_raw" \
    CLAUDE_IN="$CLAUDE_INPUT_USD_PER_MTOK" CODEX_IN="$CODEX_INPUT_USD_PER_MTOK" \
    MONTH_RE="$MONTH_ROW_RE" \
    node --input-type=module -e '
        const strip = s => s.replace(/\x1b\[[0-9;]*m/g, "");
        // Columns: Month Cmds Input Output Saved Save% Time — capture Month + Saved (5th).
        const RE = /^(\d{4}-\d{2})\s+\S+\s+\S+\s+\S+\s+(\S+)/;
        const toNum = h => { const m = String(h).trim().match(/^([\d.]+)\s*([KMGB]?)/i); if (!m) return 0; const u = (m[2]||"").toUpperCase(); return Math.round(parseFloat(m[1]) * ({K:1e3,M:1e6,G:1e9,B:1e9}[u]||1)); };
        const human = t => t>=1e6 ? (t/1e6).toFixed(1)+"M" : t>=1e3 ? (t/1e3).toFixed(1)+"K" : String(t);
        const CL = parseFloat(process.env.CLAUDE_IN), CX = parseFloat(process.env.CODEX_IN);
        let tT=0, tCl=0, tCx=0;
        for (const ln of strip(process.env.RTK_MONTHLY||"").split("\n")) {
            const m = ln.match(RE); if (!m) continue;
            const tok = toNum(m[2]); if (!tok) continue;
            const cl = tok/1e6*CL, cx = tok/1e6*CX;
            tT+=tok; tCl+=cl; tCx+=cx;
            console.log("  " + m[1].padEnd(9) + "  " + human(tok).padEnd(10) + "  " + ("$"+cl.toFixed(2)).padEnd(12) + "  $" + cx.toFixed(2));
        }
        console.log("  ─────────────────────────────────────────────────────────────");
        console.log("  " + "TOTAL".padEnd(9) + "  " + human(tT).padEnd(10) + "  " + ("$"+tCl.toFixed(2)).padEnd(12) + "  $" + tCx.toFixed(2));
    ' || echo "  (monthly parse failed)"
    echo ""
    printf "  ${COL_DIM}Savings are input-side (context offload), so output price (%s \$%s/M) is not applied. Codex price is a placeholder — edit gain.sh to match openai.com/pricing.${COL_RESET}\n" \
        "$CLAUDE_LABEL" "$CLAUDE_OUTPUT_USD_PER_MTOK"
fi

echo ""
echo "(Next: run /tokenwar check to verify the gain is real and not double-counted.)"
