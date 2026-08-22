#!/usr/bin/env bash
# tokenwar activate — install missing + enable disabled tools with confirmation.
#
# Reuses the plugin + RTK-hook logic from install.sh (marketplace add,
# plugin install/enable with anti-clobber re-enable, rtk init -g
# --auto-patch --hook-only) so the minimal install flow
#   curl .../install.sh | bash
#   /tokenwar activate
# promised by the README / install.sh final message actually works.
#
# Usage:
#   activate.sh          # interactive confirmation
#   activate.sh --yes    # skip confirmation

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# shellcheck source=lib/plugins.sh
source "${SCRIPT_DIR}/lib/plugins.sh"

readonly CLAUDE_BIN="claude"
readonly RTK_BIN="rtk"
readonly OPENCODE_BIN="opencode"

readonly PLUGIN_MARKETPLACES=(
    "mksglu/context-mode"
    "thedotmack/claude-mem"
    "JuliusBrussee/caveman"
    "DietrichGebert/ponytail"
)
readonly PLUGIN_SLUGS=(
    "context-mode@context-mode"
    "claude-mem@thedotmack"
    "caveman@caveman"
    "ponytail@ponytail"
)

readonly STATUS_OK="OK"
readonly STATUS_DISABLED="installed-disabled"
readonly STATUS_MISSING="not-installed"

readonly TTY_DEVICE="${TW_TTY:-/dev/tty}"
readonly COL_GREEN=$'\033[32m'
readonly COL_YELLOW=$'\033[33m'
readonly COL_RED=$'\033[31m'
readonly COL_RESET=$'\033[0m'
readonly COL_DIM=$'\033[2m'

say()  { printf '%s %s\n' "${COL_GREEN}==>${COL_RESET}" "$*"; }
warn() { printf '%s %s\n' "${COL_YELLOW}!!${COL_RESET}" "$*" >&2; }

tty_readable() { { : <"$TTY_DEVICE"; } 2>/dev/null; }

assume_yes=false
for arg in "$@"; do
    case "$arg" in
        --yes|-y) assume_yes=true ;;
        -h|--help|help)
            cat <<EOF
tokenwar activate — install missing + enable disabled tools

Usage: tokenwar activate [--yes]

  --yes   skip confirmation prompt and apply immediately
EOF
            exit 0 ;;
        *) echo "unknown arg: $arg" >&2; exit 2 ;;
    esac
done

PLUGIN_LIST_JSON=""
load_plugin_list_once() {
    [[ -n "$PLUGIN_LIST_JSON" ]] && return
    PLUGIN_LIST_JSON="$(TW_CLAUDE_BIN="$CLAUDE_BIN" tw_load_plugin_list)"
}

plugin_state() {
    local slug="$1"
    load_plugin_list_once
    PLUGIN_QUERY="$slug" PLUGIN_LIST_JSON="$PLUGIN_LIST_JSON" node --input-type=module -e "
        const arr = JSON.parse(process.env.PLUGIN_LIST_JSON || '[]');
        const slug = process.env.PLUGIN_QUERY;
        const entry = arr.find(p => p.id === slug);
        if (!entry)         { console.log('$STATUS_MISSING'); process.exit(0); }
        if (!entry.enabled) { console.log('$STATUS_DISABLED'); process.exit(0); }
        console.log('$STATUS_OK');
    " 2>/dev/null || echo "$STATUS_MISSING"
}

list_enabled_ids() {
    "$CLAUDE_BIN" plugin list --json 2>/dev/null | node --input-type=module -e '
        let s = "";
        process.stdin.on("data", d => s += d).on("end", () => {
            let arr = [];
            try { arr = JSON.parse(s || "[]"); } catch {}
            for (const p of arr) if (p && p.enabled) console.log(p.id);
        });
    ' 2>/dev/null || true
}

install_plugins() {
    if ! command -v "$CLAUDE_BIN" >/dev/null 2>&1; then
        warn "claude CLI not found — skipping plugin install. Install Claude Code, then re-run activate."
        return 0
    fi
    say "Installing/enabling the 4 Claude Code plugins"

    local mp
    for mp in "${PLUGIN_MARKETPLACES[@]}"; do
        "$CLAUDE_BIN" plugin marketplace add "$mp" >/dev/null 2>&1 \
            || warn "marketplace add $mp failed (may already be registered)"
    done

    local before_enabled
    before_enabled="$(list_enabled_ids)"

    local slug
    for slug in "${PLUGIN_SLUGS[@]}"; do
        "$CLAUDE_BIN" plugin install "$slug" >/dev/null 2>&1 || warn "install $slug failed"
        "$CLAUDE_BIN" plugin enable  "$slug" >/dev/null 2>&1 || true
    done

    local now_enabled id
    now_enabled="$(list_enabled_ids)"
    while IFS= read -r id; do
        [[ -z "$id" ]] && continue
        if ! grep -qxF "$id" <<<"$now_enabled"; then
            warn "re-enabling $id (clobbered by plugin enable)"
            "$CLAUDE_BIN" plugin enable "$id" >/dev/null 2>&1 || true
        fi
    done <<<"$before_enabled"

    say "Plugins installed + enabled. Restart Claude Code to load them."
}

wire_rtk_hook() {
    if command -v "$RTK_BIN" >/dev/null 2>&1; then
        say "Wiring RTK hook (rtk init -g --auto-patch --hook-only)"
        "$RTK_BIN" init -g --auto-patch --hook-only >/dev/null 2>&1 || warn "rtk init -g --auto-patch --hook-only failed — run it manually"
        if command -v "$OPENCODE_BIN" >/dev/null 2>&1; then
            say "Installing RTK opencode plugin (rtk init -g --opencode)"
            "$RTK_BIN" init -g --opencode >/dev/null 2>&1 \
                || warn "rtk init -g --opencode failed — run it manually (restart opencode after)"
        fi
    else
        warn "rtk binary not found — install it with install.sh --with-rtk (or run \`rtk init -g\` after installing the RTK CLI)."
    fi
}

rtk_hook_needed() {
    if ! command -v "$RTK_BIN" >/dev/null 2>&1; then
        echo "missing-binary"
        return
    fi
    if "$RTK_BIN" gain 2>/dev/null | grep -q "No hook installed"; then
        echo "hook-missing"
        return
    fi
    echo "ok"
}

# === detect ===
echo ""
echo "${COL_GREEN}# /tokenwar activate${COL_RESET}"
echo ""

needs_fix=false
declare -a plan_lines=()

for slug in "${PLUGIN_SLUGS[@]}"; do
    st="$(plugin_state "$slug")"
    if [[ "$st" != "$STATUS_OK" ]]; then
        needs_fix=true
        short="${slug%%@*}"
        if [[ "$st" == "$STATUS_MISSING" ]]; then
            plan_lines+=("  - $short ($slug): not-installed → will marketplace add + install + enable")
        else
            plan_lines+=("  - $short ($slug): installed-disabled → will enable")
        fi
    fi
done

rtk_status="$(rtk_hook_needed)"
if [[ "$rtk_status" == "hook-missing" ]]; then
    needs_fix=true
    plan_lines+=("  - rtk: hook missing → will run rtk init -g --auto-patch --hook-only")
    if command -v "$OPENCODE_BIN" >/dev/null 2>&1; then
        plan_lines+=("  - rtk opencode plugin: will run rtk init -g --opencode (opencode detected)")
    fi
elif [[ "$rtk_status" == "missing-binary" ]]; then
    # Do not treat missing binary as a fixable item via activate (requires --with-rtk);
    # surface as note but do not block "already active" when plugins are OK.
    :
fi

if ! $needs_fix; then
    echo "All managed plugins already active and RTK hook wired — nothing to do."
    echo ""
    if [[ -x "${SCRIPT_DIR}/status.sh" ]]; then
        bash "${SCRIPT_DIR}/status.sh" || true
    fi
    exit 0
fi

echo "The following actions will be applied:"
for line in "${plan_lines[@]}"; do
    echo "$line"
done
echo ""

# === confirm ===
if ! $assume_yes; then
    reply=""
    if tty_readable; then
        printf "Apply these fixes? [y/N] "
        read -r reply <"$TTY_DEVICE" 2>/dev/null || reply=""
    fi
    case "$reply" in
        y|Y|yes|YES) ;;
        *)
            if [[ -z "$reply" ]]; then
                warn "No interactive terminal — re-run with --yes to apply. Skipped."
            else
                say "Skipped."
            fi
            exit 0
            ;;
    esac
fi

# === apply ===
install_plugins
# Wire hook only if needed, but wire_rtk_hook is idempotent — gate on hook-missing or always?
if [[ "$rtk_status" == "hook-missing" ]]; then
    wire_rtk_hook
elif [[ "$rtk_status" == "ok" ]]; then
    # Already wired; still ensure opencode plugin when opencode present and hook is ok?
    # Keep idempotent: if opencode present, ensure plugin (rtk init is cheap).
    if command -v "$OPENCODE_BIN" >/dev/null 2>&1 && command -v "$RTK_BIN" >/dev/null 2>&1; then
        # Only run opencode wiring if plugin not yet installed could be detected via rtk init --show,
        # but for minimal diff just wire when hook was missing. Skip here to avoid extra work.
        :
    fi
fi

echo ""
say "Activate complete. Verifying..."
echo ""
if [[ -x "${SCRIPT_DIR}/status.sh" ]]; then
    bash "${SCRIPT_DIR}/status.sh" || true
fi
