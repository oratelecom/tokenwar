#!/usr/bin/env bash
# tokenwar launch banner — shown when a wrapped CLI starts.
#
# Codex, Gemini, and Kimi do NOT expose a persistent status-bar API the way Claude
# Code does (their footers are hardcoded in their TUIs). The closest we can do
# without touching their binaries is a one-time banner at launch:
#   1. print the tokenwar stack bar (same renderer as the Claude statusline)
#   2. remind the user that `tokenwar status` shows the full state on demand
#   3. if updates are pending (from the throttled cache), offer to upgrade now
#
# This is intentionally non-blocking and silent for non-interactive launches
# (`codex exec`, `gemini -p ...`, `kimi -p ...`, pipes) so it never pollutes
# scripted output.
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
readonly UPGRADE_SCRIPT="${SCRIPT_DIR}/upgrade.sh"
readonly UPGRADE_CACHE_FILE="${HOME}/.claude/tokenwar/upgrade-check.json"
readonly STATE_UPDATE="update-available"
readonly UPGRADE_PROMPT_TIMEOUT_SECS=10

readonly COL_DIM=$'\033[2m'
readonly COL_YELLOW=$'\033[33m'
readonly COL_RESET=$'\033[0m'

# Non-interactive subcommands that must NEVER get a banner (scripted/automation
# entrypoints whose stdout is consumed by tooling).
readonly NONINTERACTIVE_SUBCMDS=" exec e completion mcp mcp-server app-server apply a review cloud exec-server resume fork "

# Bail silently unless this is a genuine interactive TUI launch.
should_banner() {
    # No controlling terminal on stdout → scripted/piped, skip.
    [[ -t 1 ]] || return 1
    # First positional arg matching a non-interactive subcommand → skip.
    local first="${1:-}"
    if [[ -n "$first" && "$NONINTERACTIVE_SUBCMDS" == *" $first "* ]]; then
        return 1
    fi
    # Gemini headless flags.
    for a in "$@"; do
        case "$a" in
            -p|--prompt|-o|--output-format|-l|--list-extensions|--list-sessions) return 1 ;;
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

# 3. update offer — read the throttled cache only (no network here).
update_count=0
if [[ -f "$UPGRADE_CACHE_FILE" ]]; then
    update_count=$(
        CACHE="$UPGRADE_CACHE_FILE" TW_STATE="$STATE_UPDATE" node --input-type=module -e '
            import { readFileSync } from "node:fs";
            let d; try { d = JSON.parse(readFileSync(process.env.CACHE, "utf8")); } catch { console.log(0); process.exit(0); }
            const buckets = [d.tools || {}, d.providers || {}];
            let n = 0;
            for (const b of buckets) for (const v of Object.values(b)) if (v && v.state === process.env.TW_STATE) n++;
            console.log(n);
        ' 2>/dev/null || echo 0
    )
fi
update_count="${update_count:-0}"

if (( update_count > 0 )); then
    word="updates"; (( update_count == 1 )) && word="update"
    printf "%s⬆ %d %s available.%s Upgrade now? [y/N] (auto-skip in %ds) " \
        "$COL_YELLOW" "$update_count" "$word" "$COL_RESET" "$UPGRADE_PROMPT_TIMEOUT_SECS"
    reply=""
    if { : </dev/tty; } 2>/dev/null; then
        read -r -t "$UPGRADE_PROMPT_TIMEOUT_SECS" reply </dev/tty 2>/dev/null || reply=""
    fi
    echo ""
    case "$reply" in
        y|Y|yes|YES)
            if [[ -x "$UPGRADE_SCRIPT" ]]; then
                bash "$UPGRADE_SCRIPT" --yes || true
            fi
            ;;
        *) : ;;  # skip — banner is best-effort, never blocks the launch
    esac
fi

exit 0
