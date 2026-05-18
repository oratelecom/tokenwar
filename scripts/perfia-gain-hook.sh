#!/usr/bin/env bash
# perfia gain telemetry hook
#
# Installable via /perfia activate. When wired into Claude Code's
# PostToolUse hook (or wrapped around claude-mem / caveman invocations),
# it logs compression events to ~/.claude/perfia/gain.jsonl so that
# /perfia gain can report numbers for tools that have no native telemetry.
#
# Inputs (env):
#   PERFIA_TOOL       — required, one of: claude-mem | caveman
#   PERFIA_BYTES_IN   — required, integer
#   PERFIA_BYTES_OUT  — required, integer
#   PERFIA_NOTE       — optional, free-form short note
#
# This script is intentionally minimal: append a JSONL row, never block,
# never error out to the parent process. Failures are silent on stderr
# so they don't corrupt the host tool's output.

set -uo pipefail

readonly LOG_DIR="${HOME}/.claude/perfia"
readonly LOG_FILE="${LOG_DIR}/gain.jsonl"

tool="${PERFIA_TOOL:-}"
bytes_in="${PERFIA_BYTES_IN:-}"
bytes_out="${PERFIA_BYTES_OUT:-}"
note="${PERFIA_NOTE:-}"

if [[ -z "$tool" || -z "$bytes_in" || -z "$bytes_out" ]]; then
    echo "perfia-gain-hook: missing required env (PERFIA_TOOL, PERFIA_BYTES_IN, PERFIA_BYTES_OUT)" >&2
    exit 0
fi

if ! mkdir -p "$LOG_DIR" 2>/dev/null; then
    echo "perfia-gain-hook: cannot create $LOG_DIR" >&2
    exit 0
fi

ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
# Escape note for JSON via node (safer than sed-quoting)
escaped_note=$(PERFIA_NOTE_RAW="$note" node --input-type=module -e \
    "console.log(JSON.stringify(process.env.PERFIA_NOTE_RAW || ''))" 2>/dev/null || echo '""')

printf '{"ts":"%s","tool":"%s","bytes_in":%s,"bytes_out":%s,"note":%s}\n' \
    "$ts" "$tool" "$bytes_in" "$bytes_out" "$escaped_note" \
    >> "$LOG_FILE" 2>/dev/null || true
exit 0
