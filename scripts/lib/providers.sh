#!/usr/bin/env bash
# tokenwar providers — single-source registry for all AI coding providers.
#
# Each provider is indexed 0..N-1. Call provider_* functions with the index.
# To iterate: for i in $(seq 0 $((PROVIDER_COUNT - 1))); do ... done
#
# Telemetry sources (native, never fabricated):
#   Claude — RTK (rtk gain), context-mode (ctx_stats MCP), claude-mem (chroma-sync-state)
#   Codex  — ~/.codex/state_5.sqlite → threads.tokens_used (real per-session counts)
#   Gemini — no local token store; CLI detection only, telemetry N/A
#   Kimi   — ~/.kimi-code stores sessions/config, but no documented token store

set -euo pipefail

# These constants form the registry's public API — they are read by the scripts
# that source this file (gain.sh, status.sh, check.sh, check-updates.sh,
# tokenwar-statusline.sh), not within this file, hence the SC2034 suppressions.
# shellcheck disable=SC2034
readonly PROVIDER_COUNT=4
# shellcheck disable=SC2034
readonly PROVIDER_IDX_CODEX=1
# shellcheck disable=SC2034
readonly PROVIDER_IDX_GEMINI=2
# shellcheck disable=SC2034
readonly PROVIDER_IDX_KIMI=3

readonly CODEX_STATE_DB="${HOME}/.codex/state_5.sqlite"
readonly KIMI_CODE_HOME="${KIMI_CODE_HOME:-${HOME}/.kimi-code}"
# CHARS_PER_TOKEN is defined in gain.sh (primary consumer)

# ── provider metadata ────────────────────────────────────────────────

provider_id() {
    case "$1" in
        0) echo "claude" ;;
        1) echo "codex"  ;;
        2) echo "gemini" ;;
        3) echo "kimi"   ;;
    esac
}

provider_name() {
    case "$1" in
        0) echo "Claude Code" ;;
        1) echo "Codex"       ;;
        2) echo "Gemini CLI"  ;;
        3) echo "Kimi Code CLI" ;;
    esac
}

provider_cli() {
    case "$1" in
        0) echo "claude" ;;
        1) echo "codex"  ;;
        2) echo "gemini" ;;
        3) echo "kimi"   ;;
    esac
}

provider_input_usd_per_mtok() {
    case "$1" in
        0) echo "5.00"  ;;  # Claude Opus 4.8 input (claude-api skill, 2026-05-26)
        1) echo "1.25"  ;;  # Codex (gpt-5-codex) input — VERIFY at openai.com/pricing
        2) echo "1.25"  ;;  # Gemini 2.5 Pro input — VERIFY at ai.google.dev/pricing
        3) echo "0.30"  ;;  # Kimi K2/Kimi Code input — VERIFY at platform.kimi.ai/pricing
    esac
}

provider_label() {
    case "$1" in
        0) echo "Claude Opus 4.8"      ;;
        1) echo "Codex (gpt-5-codex)"  ;;
        2) echo "Gemini 2.5 Pro"        ;;
        3) echo "Kimi Code"             ;;
    esac
}

provider_config_dir() {
    case "$1" in
        0) echo "${HOME}/.claude" ;;
        1) echo "${HOME}/.codex" ;;
        2) echo "${HOME}/.gemini" ;;
        3) echo "$KIMI_CODE_HOME" ;;
    esac
}

provider_is_installed() {
    local cli
    cli=$(provider_cli "$1")
    command -v "$cli" >/dev/null 2>&1
}

provider_version() {
    local cli
    cli=$(provider_cli "$1")
    if ! command -v "$cli" >/dev/null 2>&1; then echo "-"; return; fi
    "$cli" --version 2>/dev/null | head -1 | sed 's/^[^0-9]*//' | awk '{print $1}'
}

# ── telemetry: total tokens saved per provider ────────────────────────
#
# Returns: human_readable|note|numeric_tokens
# Codex reads its own SQLite (real tokens_used per session).
# Gemini has no local token store → honest N/A.
# Claude telemetry is handled externally (RTK + context-mode + claude-mem
# are surfaced as tools, not as a single provider line).

provider_telemetry_total() {
    case "$1" in
        0) echo "N/A|Claude aggregated from tools (see per-tool rows)|0" ;;
        1) codex_telemetry_total ;;
        2) gemini_telemetry_total ;;
        3) kimi_telemetry_total ;;
    esac
}

provider_telemetry_monthly() {
    case "$1" in
        0) echo "" ;;  # Claude monthly from RTK — handled separately
        1) codex_telemetry_monthly ;;
        2) gemini_telemetry_monthly ;;
        3) kimi_telemetry_monthly ;;
    esac
}

# ── Codex native telemetry (SQLite) ───────────────────────────────────

codex_telemetry_total() {
    if [[ ! -f "$CODEX_STATE_DB" ]]; then
        echo "N/A|Codex state DB not found ($CODEX_STATE_DB)|0"; return
    fi
    if ! command -v python3 >/dev/null 2>&1; then
        echo "N/A|python3 required to read Codex DB|0"; return
    fi
    CODEX_DB="$CODEX_STATE_DB" python3 -c "
import sqlite3, os, sys
try:
    db = sqlite3.connect(os.environ['CODEX_DB'])
    row = db.execute('SELECT SUM(tokens_used), COUNT(*) FROM threads WHERE tokens_used > 0').fetchone()
    if not row or row[0] is None:
        print('N/A|no Codex sessions with tokens|0')
        sys.exit(0)
    tokens = int(row[0])
    sessions = int(row[1])
    human = f'{tokens/1e6:.1f}M' if tokens >= 1e6 else f'{tokens/1e3:.1f}K' if tokens >= 1e3 else str(tokens)
    print(f'{human}|{sessions} Codex sessions (real tokens_used)|{tokens}')
except Exception as e:
    print(f'N/A|Codex DB read failed: {e}|0')
" 2>/dev/null || echo "N/A|Codex DB query failed|0"
}

codex_telemetry_monthly() {
    if [[ ! -f "$CODEX_STATE_DB" ]]; then echo ""; return; fi
    if ! command -v python3 >/dev/null 2>&1; then echo ""; return; fi
    CODEX_DB="$CODEX_STATE_DB" python3 -c "
import sqlite3, os, sys
try:
    db = sqlite3.connect(os.environ['CODEX_DB'])
    rows = db.execute('''
        SELECT strftime('%Y-%m', datetime(created_at, 'unixepoch')) as m,
               SUM(tokens_used), COUNT(*)
        FROM threads WHERE tokens_used > 0 AND created_at > 0
        GROUP BY m ORDER BY m
    ''').fetchall()
    for r in rows:
        print(f'{r[0]} {r[1]} {r[2]}')
except Exception:
    pass
" 2>/dev/null || echo ""
}

# ── Gemini telemetry — no local token store ───────────────────────────

gemini_telemetry_total() {
    if ! command -v gemini >/dev/null 2>&1; then
        echo "N/A|Gemini CLI not installed|0"; return
    fi
    # Gemini has no local token-count store (no SQLite, no history.jsonl with
    # token fields). It stores sessions server-side. Honest N/A until Google
    # exposes token counts via CLI or API.
    echo "N/A|no local token telemetry (Gemini stores sessions server-side)|0"
}

gemini_telemetry_monthly() {
    echo ""  # No monthly data available
}

# ── Kimi telemetry — no documented local token-count store ───────────

kimi_telemetry_total() {
    if ! command -v kimi >/dev/null 2>&1; then
        echo "N/A|Kimi Code CLI not installed|0"; return
    fi
    echo "N/A|no documented local token telemetry (${KIMI_CODE_HOME})|0"
}

kimi_telemetry_monthly() {
    echo ""  # No monthly data available
}
