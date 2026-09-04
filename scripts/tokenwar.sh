#!/usr/bin/env bash
# tokenwar dispatcher — a single entrypoint usable from ANY shell or CLI.
#
# The Claude Code skill exposes `/tokenwar <sub>`. Outside Claude (Codex,
# Gemini, plain shell) there is no slash command, so this dispatcher gives the
# same verbs as a normal command:
#
#   tokenwar status     # state of the 7 tools + providers
#   tokenwar gain       # per-tool + per-provider token savings
#   tokenwar scan       # local agent-log scan + recommendations
#   tokenwar check      # complementarity / conflict detector
#   tokenwar test       # end-to-end ping: is each tool actually working?
#   tokenwar upgrade    # bump managed tools (asks confirmation)
#   tokenwar updates    # show available updates (throttled cache)
#   tokenwar doctor     # full pipeline: status → test → check → gain
#   tokenwar disable X  # turn off one tool without uninstalling it
#   tokenwar enable  X  # turn it back on
#
# install.sh wires a `tokenwar` shell function pointing here, so users type
# `tokenwar status` directly.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

usage() {
    cat <<EOF
tokenwar — token-saving stack manager

Usage: tokenwar <command>

Commands:
  status     state of the 7 tools + providers (codex, gemini, kimi, opencode)
  gain       per-tool + per-provider token savings + monthly \$ value
  scan       scan local agent logs and recommend token-saving tools
  check      complementarity / conflict detector
  test       end-to-end ping: is each tool actually working?
  upgrade    bump managed tools to latest (asks confirmation)
  updates    show available updates (throttled 24h cache)
  doctor     full pipeline: status -> test -> check -> gain
  disable X  turn off one tool (context-mode|claude-mem|caveman|ponytail) without uninstalling it
  enable X   turn one tool back on
  help       this message
EOF
}

cmd="${1:-status}"
shift || true

case "$cmd" in
    status)  exec bash "${SCRIPT_DIR}/status.sh" "$@" ;;
    gain)    exec bash "${SCRIPT_DIR}/gain.sh" "$@" ;;
    scan)    exec bash "${SCRIPT_DIR}/scan.sh" "$@" ;;
    check)   exec bash "${SCRIPT_DIR}/check.sh" "$@" ;;
    test)
        bash "${SCRIPT_DIR}/status.sh" --test "$@"
        rc=$?
        echo ""
        echo "note: context-mode ping requires the ctx_stats MCP tool (shell cannot reach it — caller must invoke ctx_stats separately; see status.sh header)."
        exit $rc
        ;;
    upgrade) exec bash "${SCRIPT_DIR}/upgrade.sh" "$@" ;;
    updates) exec bash "${SCRIPT_DIR}/check-updates.sh" "$@" ;;
    enable|disable) exec bash "${SCRIPT_DIR}/toggle.sh" "$cmd" "$@" ;;
    doctor)
        bash "${SCRIPT_DIR}/status.sh" --test || true
        bash "${SCRIPT_DIR}/check.sh"  || true
        bash "${SCRIPT_DIR}/gain.sh"   || true
        ;;
    help|-h|--help) usage ;;
    *) echo "unknown command: $cmd" >&2; echo "" >&2; usage >&2; exit 2 ;;
esac
