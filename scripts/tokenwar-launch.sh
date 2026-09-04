#!/usr/bin/env bash
# tokenwar launch banner — shown when a wrapped CLI starts.
#
# Codex, Gemini, Kimi, opencode, and GitHub Copilot CLI do NOT expose a
# persistent status-bar API the way Claude Code does (their footers are
# hardcoded in their TUIs). The closest we can do without touching their
# binaries is a one-time banner at launch:
#   1. print the tokenwar stack bar (same renderer as the Claude statusline)
#   2. remind the user that `tokenwar status` shows the full state on demand
#   3. leave upgrade drift as a statusline hint only
#
# This is intentionally non-blocking and silent for non-interactive launches
# (`codex exec`, `gemini -p ...`, `kimi -p ...`, `opencode run ...`,
# `copilot -p ...`, pipes) so it never pollutes scripted output.
#
# Usage: tokenwar-launch.sh <provider> [original CLI args...]
#   <provider> is the CLI being launched — used only for the
#   greeting line. The remaining args are inspected to decide whether this is
#   an interactive launch worth bannering.

set -uo pipefail

readonly PROVIDER="${1:-cli}"
shift || true

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly STATUSLINE_SCRIPT="${SCRIPT_DIR}/tokenwar-statusline.sh"

readonly COL_DIM=$'\033[2m'
readonly COL_YELLOW=$'\033[33m'
readonly COL_RESET=$'\033[0m'

# Non-interactive subcommands that must NEVER get a banner (scripted/automation
# entrypoints whose stdout is consumed by tooling).
# Subcommands whose stdout is consumed by tooling or which exit immediately.
# Copilot contributes app / help / init / login / plugin / plugins / skill /
# update / version on top of the shared ones (completion, mcp) it already used.
readonly NONINTERACTIVE_SUBCMDS=" exec e completion mcp mcp-server app-server apply a review cloud exec-server resume fork run serve app help init login plugin plugins skill update version "

# Bail silently unless this is a genuine interactive TUI launch.
should_banner() {
    # No controlling terminal on stdout → scripted/piped, skip.
    [[ -t 1 ]] || return 1
    # First positional arg matching a non-interactive subcommand → skip.
    local first="${1:-}"
    if [[ -n "$first" && "$NONINTERACTIVE_SUBCMDS" == *" $first "* ]]; then
        return 1
    fi
    # Headless / immediate-exit flags across the wrapped CLIs. `--acp` starts
    # Copilot as an Agent Client Protocol server, which is a machine channel.
    for a in "$@"; do
        case "$a" in
            -p|--prompt|-o|--output-format|-l|--list-extensions|--list-sessions) return 1 ;;
            --acp|-v|--version|-h|--help) return 1 ;;
        esac
    done
    return 0
}

if ! should_banner "$@"; then
    exit 0
fi

# 1. the stack bar (reuse the statusline renderer; it reads+ignores stdin JSON)
if [[ -x "$STATUSLINE_SCRIPT" ]]; then
    echo '{}' | bash "$STATUSLINE_SCRIPT" 2>/dev/null || true
    echo ""
fi

# 2. discoverability reminder
printf "%stokenwar%s · %s — run %stokenwar status%s for the full state · %stokenwar gain%s for token savings\n" \
    "$COL_YELLOW" "$COL_RESET" "$PROVIDER" \
    "$COL_DIM" "$COL_RESET" "$COL_DIM" "$COL_RESET"

exit 0
