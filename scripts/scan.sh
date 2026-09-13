#!/usr/bin/env bash
# tokenwar scan — thin wrapper around the structured scanner in scan.mjs.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

command -v node >/dev/null 2>&1 || {
    printf 'tokenwar scan: node is required (v18+).\n' >&2
    exit 127
}

export TOKENWAR_STATUS_SCRIPT="${TOKENWAR_STATUS_SCRIPT:-${SCRIPT_DIR}/status.sh}"
exec node "${SCRIPT_DIR}/scan.mjs" "$@"
