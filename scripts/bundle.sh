#!/usr/bin/env bash
# tokenwar bundle — apply a session-start tool bundle.
#
# Bundles are chosen before a session starts, never mid-session. Changing the
# available tool inventory invalidates the prompt-cache prefix, so a mid-session
# switch is billed as a full rebuild at 1.25x instead of a 0.1x read; that can
# cost more than the switch saves.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly TOGGLE="${TOKENWAR_TOGGLE_SCRIPT:-${SCRIPT_DIR}/toggle.sh}"

usage() {
    cat <<'EOF'
tokenwar bundle — apply a session-start tool bundle

Usage:
  tokenwar bundle                 show bundles and the current state
  tokenwar bundle <name>          apply a bundle (asks first)
  tokenwar bundle <name> --yes    apply without asking
  tokenwar bundle <name> --dry-run  show the changes only

Bundles:
  dev         shell output and generated code dominate
  devops      shell stdout is the whole cost; no repo graph to amortise
  architect   discovery sweeps repeat across sessions
  testing     high-volume compressible output; exactness matters

Run `tokenwar scan` first: it infers which bundle matches your logs.
EOF
}

# tool sets per bundle, space separated
bundle_enable() {
    case "$1" in
        dev)       echo "rtk caveman ponytail claude-mem" ;;
        devops)    echo "rtk caveman" ;;
        architect) echo "graphify claude-mem caveman" ;;
        testing)   echo "rtk caveman" ;;
        *)         return 1 ;;
    esac
}

bundle_disable() {
    case "$1" in
        dev)       echo "pxpipe" ;;
        devops)    echo "graphify pxpipe" ;;
        architect) echo "pxpipe" ;;
        testing)   echo "graphify pxpipe" ;;
        *)         return 1 ;;
    esac
}

bundle_why() {
    case "$1" in
        dev)       echo "Shell output and generated code dominate. Memory pays back across repeated sessions on one repo." ;;
        devops)    echo "Shell stdout is the whole cost. Repo graphs have nothing to index against infrastructure work." ;;
        architect) echo "Discovery sweeps dominate and repeat across sessions, which is what a graph and memory amortise." ;;
        testing)   echo "Test output is high-volume and compressible. Exactness matters, so no lossy payload rendering." ;;
    esac
}

if [[ $# -eq 0 ]]; then
    usage
    exit 0
fi

name=""
assume_yes=0
dry_run=0
for arg in "$@"; do
    case "$arg" in
        -h|--help) usage; exit 0 ;;
        -y|--yes)  assume_yes=1 ;;
        --dry-run) dry_run=1 ;;
        -*)        printf 'tokenwar bundle: unknown option: %s\n' "$arg" >&2; exit 2 ;;
        *)         name="$arg" ;;
    esac
done

if [[ -z "$name" ]]; then
    usage
    exit 0
fi

if ! enable_list="$(bundle_enable "$name")"; then
    printf 'tokenwar bundle: unknown bundle: %s\n\n' "$name" >&2
    usage >&2
    exit 2
fi
disable_list="$(bundle_disable "$name")"

printf '\n  Bundle: %s\n' "$name"
printf '  %s\n\n' "$(bundle_why "$name")"
printf '  enable:   %s\n' "$enable_list"
printf '  disable:  %s\n\n' "$disable_list"

if [[ $dry_run -eq 1 ]]; then
    printf '  Dry run: nothing changed.\n\n'
    exit 0
fi

printf '  Apply at the START of a session. Switching mid-session forces a\n'
printf '  cache-prefix rebuild that can cost more than the change saves.\n\n'

if [[ $assume_yes -eq 0 ]]; then
    if [[ ! -t 0 ]]; then
        printf '  Not a terminal; re-run with --yes to apply.\n' >&2
        exit 1
    fi
    printf '  Apply? [y/N] '
    IFS= read -r reply
    case "$reply" in
        y|Y|yes|YES) ;;
        *) printf '  Skipped.\n'; exit 0 ;;
    esac
fi

[[ -x "$TOGGLE" || -f "$TOGGLE" ]] || {
    printf 'tokenwar bundle: toggle script not found: %s\n' "$TOGGLE" >&2
    exit 127
}

status=0
for tool in $enable_list; do
    if bash "$TOGGLE" enable "$tool" >/dev/null 2>&1; then
        printf '  enabled   %s\n' "$tool"
    else
        printf '  skipped   %s (not installed)\n' "$tool"
        status=1
    fi
done
for tool in $disable_list; do
    if bash "$TOGGLE" disable "$tool" >/dev/null 2>&1; then
        printf '  disabled  %s\n' "$tool"
    else
        printf '  skipped   %s (not installed)\n' "$tool"
    fi
done

printf '\n  Bundle %s applied. Start a new session for a clean cache prefix.\n\n' "$name"
exit $status
