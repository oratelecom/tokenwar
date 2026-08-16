#!/usr/bin/env bash
# tokenwar enable|disable — let a user turn an individual managed tool on or off
# WITHOUT uninstalling it or hand-editing ~/.claude/settings.json.
#
#   tokenwar disable context-mode   # stop loading it, keep it installed
#   tokenwar enable  context-mode   # turn it back on
#
# The four Claude Code plugins share one native, reversible mechanism
# (`claude plugin enable|disable <slug>`), so we drive that directly. rtk and
# pxpipe are standalone binaries, not plugins — there is no plugin toggle for
# them, so we point the user at the correct per-tool mechanism instead of doing
# risky settings.json / npm surgery here.

set -euo pipefail

readonly CLAUDE_BIN="claude"

# Plugin tools: friendly name → marketplace slug (must match status.sh).
readonly SLUG_CONTEXT_MODE="context-mode@context-mode"
readonly SLUG_CLAUDE_MEM="claude-mem@thedotmack"
readonly SLUG_CAVEMAN="caveman@caveman"
readonly SLUG_PONYTAIL="ponytail@ponytail"

# Non-plugin tools we recognise but cannot toggle via `claude plugin`.
readonly NON_PLUGIN_TOOLS=" rtk pxpipe "

readonly ACTION_ENABLE="enable"
readonly ACTION_DISABLE="disable"

readonly EXIT_USAGE=2
readonly EXIT_UNSUPPORTED=3

readonly COL_GREEN=$'\033[32m'
readonly COL_YELLOW=$'\033[33m'
readonly COL_RESET=$'\033[0m'

usage() {
    cat <<EOF
tokenwar ${ACTION_ENABLE}|${ACTION_DISABLE} <tool>

Turn an individual managed tool on or off without uninstalling it.

Toggleable plugins:
  context-mode   claude-mem   caveman   ponytail

Examples:
  tokenwar ${ACTION_DISABLE} context-mode
  tokenwar ${ACTION_ENABLE}  context-mode

Note: rtk and pxpipe are standalone binaries, not Claude Code plugins, so they
are not toggled here — see the message printed when you name them.
EOF
}

# Map a friendly tool name to its plugin slug. Empty output = not a plugin.
slug_for() {
    case "$1" in
        context-mode) printf '%s' "$SLUG_CONTEXT_MODE" ;;
        claude-mem)   printf '%s' "$SLUG_CLAUDE_MEM" ;;
        caveman)      printf '%s' "$SLUG_CAVEMAN" ;;
        ponytail)     printf '%s' "$SLUG_PONYTAIL" ;;
        *)            printf '' ;;
    esac
}

action="${1:-}"
tool="${2:-}"

case "$action" in
    "$ACTION_ENABLE"|"$ACTION_DISABLE") ;;
    -h|--help|help) usage; exit 0 ;;
    *) echo "unknown action: ${action:-<none>}" >&2; echo "" >&2; usage >&2; exit "$EXIT_USAGE" ;;
esac

if [[ -z "$tool" ]]; then
    echo "missing tool name" >&2; echo "" >&2; usage >&2; exit "$EXIT_USAGE"
fi

# rtk / pxpipe are not plugins — refuse with an actionable pointer.
if [[ "$NON_PLUGIN_TOOLS" == *" $tool "* ]]; then
    case "$tool" in
        rtk)
            echo "${COL_YELLOW}rtk is a standalone binary, not a Claude Code plugin.${COL_RESET}" >&2
            echo "  enable : rtk init -g --auto-patch --hook-only" >&2
            echo "  disable: remove the 'rtk hook claude' PreToolUse hook from ~/.claude/settings.json" >&2
            ;;
        pxpipe)
            echo "${COL_YELLOW}pxpipe is a standalone proxy binary, not a Claude Code plugin.${COL_RESET}" >&2
            echo "  enable : install it (tokenwar install --with-pxpipe)" >&2
            echo "  disable: npm rm -g pxpipe-proxy" >&2
            ;;
    esac
    exit "$EXIT_UNSUPPORTED"
fi

slug="$(slug_for "$tool")"
if [[ -z "$slug" ]]; then
    echo "unknown tool: $tool" >&2; echo "" >&2; usage >&2; exit "$EXIT_USAGE"
fi

if ! command -v "$CLAUDE_BIN" >/dev/null 2>&1; then
    echo "claude CLI not found — cannot ${action} $tool" >&2
    exit 1
fi

if ! "$CLAUDE_BIN" plugin "$action" "$slug" >/dev/null 2>&1; then
    echo "claude plugin ${action} ${slug} failed" >&2
    exit 1
fi

if [[ "$action" == "$ACTION_DISABLE" ]]; then
    echo "${COL_GREEN}✓${COL_RESET} disabled ${tool} (${slug}) — still installed, just not loaded"
else
    echo "${COL_GREEN}✓${COL_RESET} enabled ${tool} (${slug})"
fi
echo "  Restart Claude Code for the change to take effect."
