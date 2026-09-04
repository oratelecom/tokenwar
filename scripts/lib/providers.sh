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
#   opencode — ~/.local/share/opencode/opencode.db → session token cols (real)
#   Copilot — ~/.copilot/session-store.db → assistant_usage_events (real, with
#             per-model rows and the AI-credit cost GitHub actually bills)

set -euo pipefail

# These constants form the registry's public API — they are read by the scripts
# that source this file (gain.sh, status.sh, check.sh, check-updates.sh,
# tokenwar-statusline.sh), not within this file, hence the SC2034 suppressions.
# shellcheck disable=SC2034
readonly PROVIDER_COUNT=6
# shellcheck disable=SC2034
readonly PROVIDER_IDX_CODEX=1
# shellcheck disable=SC2034
readonly PROVIDER_IDX_GEMINI=2
# shellcheck disable=SC2034
readonly PROVIDER_IDX_KIMI=3
# shellcheck disable=SC2034
readonly PROVIDER_IDX_OPENCODE=4
# shellcheck disable=SC2034
readonly PROVIDER_IDX_COPILOT=5

readonly CODEX_STATE_DB="${HOME}/.codex/state_5.sqlite"
readonly KIMI_CODE_HOME="${KIMI_CODE_HOME:-${HOME}/.kimi-code}"
readonly OPENCODE_DATA_HOME="${OPENCODE_DATA_HOME:-${HOME}/.local/share/opencode}"
readonly OPENCODE_STATE_DB="${OPENCODE_DATA_HOME}/opencode.db"
# COPILOT_HOME is Copilot CLI's own override for its config + state dir.
readonly COPILOT_HOME="${COPILOT_HOME:-${HOME}/.copilot}"
readonly COPILOT_STATE_DB="${COPILOT_HOME}/session-store.db"
# 1 AI credit = 1e9 nano-AIU — the unit `assistant_usage_events.total_nano_aiu`
# stores, and what the CLI prints as "AI Credits" in its exit summary.
readonly COPILOT_NANO_AIU_PER_CREDIT=1000000000
# CHARS_PER_TOKEN is defined in gain.sh (primary consumer)

# ── provider metadata ────────────────────────────────────────────────

provider_id() {
    case "$1" in
        0) echo "claude" ;;
        1) echo "codex"  ;;
        2) echo "gemini" ;;
        3) echo "kimi"   ;;
        4) echo "opencode" ;;
        5) echo "copilot" ;;
    esac
}

provider_name() {
    case "$1" in
        0) echo "Claude Code" ;;
        1) echo "Codex"       ;;
        2) echo "Gemini CLI"  ;;
        3) echo "Kimi Code CLI" ;;
        4) echo "opencode"    ;;
        # Short form on purpose: the provider tables are %-14s columns and the
        # official "GitHub Copilot CLI" overflows them. The full product name
        # lives in provider_label, which is printed unaligned.
        5) echo "Copilot CLI" ;;
    esac
}

provider_cli() {
    case "$1" in
        0) echo "claude" ;;
        1) echo "codex"  ;;
        2) echo "gemini" ;;
        3) echo "kimi"   ;;
        4) echo "opencode" ;;
        5) echo "copilot" ;;
    esac
}

provider_input_usd_per_mtok() {
    case "$1" in
        0) echo "5.00"  ;;  # Claude Opus 4.8 input (claude-api skill, 2026-05-26)
        1) echo "1.25"  ;;  # Codex (gpt-5-codex) input — VERIFY at openai.com/pricing
        2) echo "1.25"  ;;  # Gemini 2.5 Pro input — VERIFY at ai.google.dev/pricing
        3) echo "0.30"  ;;  # Kimi K2/Kimi Code input — VERIFY at platform.kimi.ai/pricing
        4) echo "3.00"  ;;  # opencode is model-agnostic (BYO provider) — representative input rate, VERIFY per your model
        # Copilot is NOT billed per token: it is a seat subscription plus AI
        # credits (premium requests on the legacy plan), and GitHub publishes no
        # per-token list price. This is a GPT-5-class input rate, so Copilot's $
        # column is an API-equivalent valuation, never an invoice. The unit that
        # IS billed — AI credits, read from total_nano_aiu — is surfaced in the
        # telemetry note. VERIFY against your plan and model.
        5) echo "1.25"  ;;
    esac
}

provider_label() {
    case "$1" in
        0) echo "Claude Opus 4.8"      ;;
        1) echo "Codex (gpt-5-codex)"  ;;
        2) echo "Gemini 2.5 Pro"        ;;
        3) echo "Kimi Code"             ;;
        4) echo "opencode (BYO model)"  ;;
        5) echo "GitHub Copilot CLI (seat + AI credits)" ;;
    esac
}

provider_config_dir() {
    case "$1" in
        0) echo "${HOME}/.claude" ;;
        1) echo "${HOME}/.codex" ;;
        2) echo "${HOME}/.gemini" ;;
        3) echo "$KIMI_CODE_HOME" ;;
        4) echo "${HOME}/.config/opencode" ;;
        5) echo "$COPILOT_HOME" ;;
    esac
}

provider_is_installed() {
    local cli
    cli=$(provider_cli "$1")
    command -v "$cli" >/dev/null 2>&1
}

# Trailing punctuation is stripped because CLIs disagree on how a version line
# ends: Copilot prints "GitHub Copilot CLI 1.0.83." (full stop, then a second
# line about updates), which would otherwise be compared as the literal
# "1.0.83." and never match a registry version.
provider_version() {
    local cli
    cli=$(provider_cli "$1")
    if ! command -v "$cli" >/dev/null 2>&1; then echo "-"; return; fi
    "$cli" --version 2>/dev/null | head -1 | sed 's/^[^0-9]*//' | awk '{print $1}' | sed 's/[.,;:]*$//'
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
        4) opencode_telemetry_total ;;
        5) copilot_telemetry_total ;;
    esac
}

provider_telemetry_monthly() {
    case "$1" in
        0) echo "" ;;  # Claude monthly from RTK — handled separately
        1) codex_telemetry_monthly ;;
        2) gemini_telemetry_monthly ;;
        3) kimi_telemetry_monthly ;;
        4) opencode_telemetry_monthly ;;
        5) copilot_telemetry_monthly ;;
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

# ── opencode native telemetry (SQLite) ───────────────────────────────
# opencode records real per-session token usage in its Drizzle SQLite DB
# (session.tokens_input/output/reasoning, time_created in epoch ms).

opencode_telemetry_total() {
    if [[ ! -f "$OPENCODE_STATE_DB" ]]; then
        echo "N/A|opencode DB not found ($OPENCODE_STATE_DB)|0"; return
    fi
    if ! command -v python3 >/dev/null 2>&1; then
        echo "N/A|python3 required to read opencode DB|0"; return
    fi
    OPENCODE_DB="$OPENCODE_STATE_DB" python3 -c "
import sqlite3, os, sys
try:
    db = sqlite3.connect(os.environ['OPENCODE_DB'])
    row = db.execute('SELECT SUM(tokens_input+tokens_output+tokens_reasoning), COUNT(*) FROM session WHERE (tokens_input+tokens_output) > 0').fetchone()
    if not row or row[0] is None:
        print('N/A|no opencode sessions with tokens|0')
        sys.exit(0)
    tokens = int(row[0])
    sessions = int(row[1])
    human = f'{tokens/1e6:.1f}M' if tokens >= 1e6 else f'{tokens/1e3:.1f}K' if tokens >= 1e3 else str(tokens)
    print(f'{human}|{sessions} opencode sessions (real token cols)|{tokens}')
except Exception as e:
    print(f'N/A|opencode DB read failed: {e}|0')
" 2>/dev/null || echo "N/A|opencode DB query failed|0"
}

opencode_telemetry_monthly() {
    if [[ ! -f "$OPENCODE_STATE_DB" ]]; then echo ""; return; fi
    if ! command -v python3 >/dev/null 2>&1; then echo ""; return; fi
    OPENCODE_DB="$OPENCODE_STATE_DB" python3 -c "
import sqlite3, os
try:
    db = sqlite3.connect(os.environ['OPENCODE_DB'])
    rows = db.execute('''
        SELECT strftime('%Y-%m', datetime(time_created/1000, 'unixepoch')) as m,
               SUM(tokens_input+tokens_output+tokens_reasoning), COUNT(*)
        FROM session WHERE (tokens_input+tokens_output) > 0 AND time_created > 0
        GROUP BY m ORDER BY m
    ''').fetchall()
    for r in rows:
        print(f'{r[0]} {r[1]} {r[2]}')
except Exception:
    pass
" 2>/dev/null || echo ""
}

# ── Copilot CLI native telemetry (SQLite) ─────────────────────────────
# Copilot CLI records one row per assistant call in `assistant_usage_events`,
# with the token breakdown AND `total_nano_aiu` — the AI-credit cost GitHub
# actually bills. Tokens go in the numeric field so the provider table stays
# comparable across CLIs; the credits go in the note, because that is the unit
# on the invoice and reporting only tokens would misstate what Copilot costs.

copilot_telemetry_total() {
    if [[ ! -f "$COPILOT_STATE_DB" ]]; then
        echo "N/A|Copilot session store not found ($COPILOT_STATE_DB)|0"; return
    fi
    if ! command -v python3 >/dev/null 2>&1; then
        echo "N/A|python3 required to read the Copilot DB|0"; return
    fi
    COPILOT_DB="$COPILOT_STATE_DB" NANO_PER_CREDIT="$COPILOT_NANO_AIU_PER_CREDIT" python3 -c "
import sqlite3, os, sys
SQL = 'SELECT SUM(COALESCE(input_tokens,0)+COALESCE(output_tokens,0)+COALESCE(reasoning_tokens,0)), COUNT(DISTINCT session_id), SUM(COALESCE(total_nano_aiu,0)) FROM assistant_usage_events'
try:
    db = sqlite3.connect(os.environ['COPILOT_DB'])
    row = db.execute(SQL).fetchone()
    if not row or row[0] is None:
        print('N/A|no Copilot sessions with token usage|0')
        sys.exit(0)
    tokens = int(row[0])
    sessions = int(row[1])
    credits = float(row[2] or 0) / float(os.environ['NANO_PER_CREDIT'])
    human = f'{tokens/1e6:.1f}M' if tokens >= 1e6 else f'{tokens/1e3:.1f}K' if tokens >= 1e3 else str(tokens)
    print(f'{human}|{sessions} Copilot sessions (real assistant_usage_events) - {credits:.2f} AI credits billed|{tokens}')
except Exception as e:
    print(f'N/A|Copilot DB read failed: {e}|0')
" 2>/dev/null || echo "N/A|Copilot DB query failed|0"
}

copilot_telemetry_monthly() {
    if [[ ! -f "$COPILOT_STATE_DB" ]]; then echo ""; return; fi
    if ! command -v python3 >/dev/null 2>&1; then echo ""; return; fi
    COPILOT_DB="$COPILOT_STATE_DB" python3 -c "
import sqlite3, os
SQL = \"SELECT strftime('%Y-%m', created_at) AS m, SUM(COALESCE(input_tokens,0)+COALESCE(output_tokens,0)+COALESCE(reasoning_tokens,0)), COUNT(DISTINCT session_id) FROM assistant_usage_events WHERE created_at IS NOT NULL GROUP BY m ORDER BY m\"
try:
    db = sqlite3.connect(os.environ['COPILOT_DB'])
    for r in db.execute(SQL).fetchall():
        if r[0] and r[1]:
            print(f'{r[0]} {r[1]} {r[2]}')
except Exception:
    pass
" 2>/dev/null || echo ""
}
