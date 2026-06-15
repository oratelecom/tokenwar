#!/usr/bin/env bash
# tokenwar dispatcher — a single entrypoint usable from ANY shell or CLI.
#
# The Claude Code skill exposes `/tokenwar <sub>`. Outside Claude (Codex,
# Gemini, plain shell) there is no slash command, so this dispatcher gives the
# same verbs as a normal command:
#
#   tokenwar status     # state of the 5 tools + providers
#   tokenwar gain       # per-tool + per-provider token savings
#   tokenwar check      # complementarity / conflict detector
#   tokenwar upgrade    # bump the 4 tools (asks confirmation)
#   tokenwar updates    # show available updates (throttled cache)
#   tokenwar doctor     # status → check → gain
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
  status     state of the 5 tools + providers (codex, gemini)
  gain       per-tool + per-provider token savings + monthly \$ value
  check      complementarity / conflict detector
  upgrade    bump the 4 tools to latest (asks confirmation)
  updates    show available updates (throttled 24h cache)
  doctor     full pipeline: status -> check -> gain
  help       this message
EOF
}

cmd="${1:-status}"
shift || true

case "$cmd" in
    status)  exec bash "${SCRIPT_DIR}/status.sh" "$@" ;;
    gain)    exec bash "${SCRIPT_DIR}/gain.sh" "$@" ;;
    check)   exec bash "${SCRIPT_DIR}/check.sh" "$@" ;;
    upgrade) exec bash "${SCRIPT_DIR}/upgrade.sh" "$@" ;;
    updates) exec bash "${SCRIPT_DIR}/check-updates.sh" "$@" ;;
    doctor)
        bash "${SCRIPT_DIR}/status.sh" || true
        bash "${SCRIPT_DIR}/check.sh"  || true
        bash "${SCRIPT_DIR}/gain.sh"   || true
        ;;
    help|-h|--help) usage ;;
    *) echo "unknown command: $cmd" >&2; echo "" >&2; usage >&2; exit 2 ;;
esac
