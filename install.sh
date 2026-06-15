#!/usr/bin/env bash
# tokenwar one-shot installer.
#
#   curl -fsSL https://raw.githubusercontent.com/oratelecom/tokenwar/main/install.sh | bash
#   curl -fsSL .../install.sh | bash -s -- --with-plugins   # + the 4 plugins
#   curl -fsSL .../install.sh | bash -s -- --all            # + plugins + RTK binary
#
# Does:
#   1. git clone https://github.com/oratelecom/tokenwar ~/.claude/skills/tokenwar
#   2. chmod +x scripts/*.sh
#   3. patch ~/.claude/settings.json to wire the statusLine
#   4. wire the tokenwar/codex/gemini shell functions
#   5. opt-in installs (none by default — no surprise mutation):
#      --with-plugins  marketplace add + install + enable the 4 Claude Code
#                      plugins (context-mode, claude-mem, caveman, ponytail),
#                      with anti-clobber re-enable.
#      --with-rtk      install the RTK binary via rtk's official prebuilt
#                      installer (cargo/rustup only as a fallback), then wire it.
#      --all           both. After either, RTK's hook is wired via `rtk init -g`.
#      Without any flag, plugin/RTK setup is left to /tokenwar activate.
#
# Idempotent: re-running pulls the latest tokenwar and only patches settings.json
# if the statusLine is not already pointing at the tokenwar script.

set -euo pipefail

REPO_URL="${TOKENWAR_REPO_URL:-https://github.com/oratelecom/tokenwar}"
INSTALL_DIR="${TOKENWAR_DIR:-$HOME/.claude/skills/tokenwar}"
SETTINGS_JSON="$HOME/.claude/settings.json"
STATUSLINE_CMD='bash ~/.claude/skills/tokenwar/scripts/tokenwar-statusline.sh'

readonly CLAUDE_BIN="claude"
# The 4 Claude Code plugins of the stack, paired with the upstream marketplace
# repo each is published from. RTK is intentionally absent — it is a Rust binary
# + settings hook, not a plugin.
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

# RTK binary install (--with-rtk). Primary path is rtk's OWN official installer,
# which downloads a prebuilt binary (no toolchain) for every major platform.
# Pinned to a release tag so the script we pipe to sh is fixed/reviewable; both
# the ref and the git source are env-overridable. cargo is only a fallback for
# platforms with no prebuilt asset.
readonly RTK_BIN="rtk"
readonly RTK_INSTALL_REF="${TOKENWAR_RTK_INSTALL_REF:-v0.42.4}"
readonly RTK_INSTALL_URL="https://raw.githubusercontent.com/rtk-ai/rtk/${RTK_INSTALL_REF}/install.sh"
readonly RTK_GIT_URL="${TOKENWAR_RTK_GIT_URL:-https://github.com/rtk-ai/rtk}"
readonly RTK_LOCAL_BIN="$HOME/.local/bin"
readonly RUSTUP_URL="https://sh.rustup.rs"

# Shell-integration block markers — used to idempotently inject/remove the
# `tokenwar`, `codex`, and `gemini` wrapper functions in the user's shell rc.
readonly TW_RC_BEGIN="# >>> tokenwar shell integration >>>"
readonly TW_RC_END="# <<< tokenwar shell integration <<<"

color()  { printf '\033[%sm%s\033[0m' "$1" "$2"; }
green()  { color 32 "$1"; }
yellow() { color 33 "$1"; }
red()    { color 31 "$1"; }
say()    { printf '%s %s\n' "$(green '==>')" "$*"; }
warn()   { printf '%s %s\n' "$(yellow '!!')" "$*" >&2; }
die()    { printf '%s %s\n' "$(red 'ERR')" "$*" >&2; exit 1; }

WITH_PLUGINS=false
WITH_RTK=false
for arg in "$@"; do
    case "$arg" in
        --with-plugins) WITH_PLUGINS=true ;;
        --with-rtk)     WITH_RTK=true ;;
        --all)          WITH_PLUGINS=true; WITH_RTK=true ;;
        -h|--help)
            printf 'Usage: install.sh [--with-plugins] [--with-rtk] [--all]\n'
            printf '  --with-plugins  install+enable the 4 Claude Code plugins (incl. ponytail)\n'
            printf '  --with-rtk      install the RTK binary (official prebuilt installer) + wire its hook\n'
            printf '  --all           both of the above\n'
            exit 0 ;;
        *) die "unknown argument: $arg (supported: --with-plugins, --with-rtk, --all)" ;;
    esac
done

command -v git >/dev/null  || die "git is required"
command -v node >/dev/null || die "node is required (used to patch settings.json)"

# 1. clone or update
if [[ -d "$INSTALL_DIR/.git" ]]; then
    say "Updating existing tokenwar checkout at $INSTALL_DIR"
    git -C "$INSTALL_DIR" pull --ff-only
elif [[ -e "$INSTALL_DIR" ]]; then
    # Directory (or file) exists but is NOT a git checkout — e.g. an older
    # manual copy. `git clone` refuses a non-empty target, so move the old
    # one aside (never silently delete the user's data) and clone fresh.
    backup="${INSTALL_DIR}.bak-$(date +%Y%m%d-%H%M%S)"
    warn "$INSTALL_DIR exists but is not a git checkout — backing it up to $backup"
    mv "$INSTALL_DIR" "$backup" || die "could not move $INSTALL_DIR aside"
    say "Cloning tokenwar into $INSTALL_DIR"
    mkdir -p "$(dirname "$INSTALL_DIR")"
    git clone "$REPO_URL" "$INSTALL_DIR"
else
    say "Cloning tokenwar into $INSTALL_DIR"
    mkdir -p "$(dirname "$INSTALL_DIR")"
    git clone "$REPO_URL" "$INSTALL_DIR"
fi

# 2. chmod scripts
say "Marking scripts executable"
chmod +x "$INSTALL_DIR"/scripts/*.sh

# 3. patch settings.json (statusLine)
say "Wiring statusLine in $SETTINGS_JSON"
mkdir -p "$(dirname "$SETTINGS_JSON")"
[[ -f "$SETTINGS_JSON" ]] || echo '{}' > "$SETTINGS_JSON"

SETTINGS_JSON="$SETTINGS_JSON" STATUSLINE_CMD="$STATUSLINE_CMD" node --input-type=module -e '
import { readFileSync, writeFileSync, copyFileSync } from "fs";
const path = process.env.SETTINGS_JSON;
const desired = process.env.STATUSLINE_CMD;
let cfg = {};
try { cfg = JSON.parse(readFileSync(path, "utf8")); } catch (e) { cfg = {}; }
const already = cfg.statusLine && cfg.statusLine.type === "command" && cfg.statusLine.command === desired;
if (already) {
    console.log("    statusLine already wired — leaving settings.json alone");
    process.exit(0);
}
const stamp = new Date().toISOString().replace(/[:.]/g, "-");
copyFileSync(path, `${path}.bak-${stamp}`);
cfg.statusLine = { type: "command", command: desired };
writeFileSync(path, JSON.stringify(cfg, null, 2) + "\n");
console.log(`    patched (backup at ${path}.bak-${stamp})`);
'

# 4. wire shell integration (tokenwar/codex/gemini functions) into shell rc.
#
# Claude Code shows the native statusLine; Codex and Gemini do not expose a
# status-bar API, so we wrap their launch with a banner + reminder + upgrade
# prompt. The `tokenwar` function makes `tokenwar status` work in any shell.
# Idempotent: an existing tokenwar block is replaced, never duplicated.
wire_shell_rc() {
    local rc_file="$1"
    [[ -f "$rc_file" ]] || return 0

    # Strip any previous tokenwar block (between markers) to a temp copy.
    local tmp
    tmp="$(mktemp "${rc_file}.tokenwar.XXXXXX")" || { warn "mktemp failed for $rc_file"; return 1; }
    TW_BEGIN="$TW_RC_BEGIN" TW_END="$TW_RC_END" awk '
        $0 == ENVIRON["TW_BEGIN"] { skip = 1 }
        skip != 1 { print }
        $0 == ENVIRON["TW_END"]   { skip = 0 }
    ' "$rc_file" > "$tmp" || { warn "could not rewrite $rc_file"; rm -f "$tmp"; return 1; }

    # Append a fresh block.
    {
        printf '%s\n' "$TW_RC_BEGIN"
        printf '%s\n' "tokenwar() { command bash \"\$HOME/.claude/skills/tokenwar/scripts/tokenwar.sh\" \"\$@\"; }"
        printf '%s\n' "codex() { command bash \"\$HOME/.claude/skills/tokenwar/scripts/tokenwar-launch.sh\" codex \"\$@\"; command codex \"\$@\"; }"
        printf '%s\n' "gemini() { command bash \"\$HOME/.claude/skills/tokenwar/scripts/tokenwar-launch.sh\" gemini \"\$@\"; command gemini \"\$@\"; }"
        printf '%s\n' "$TW_RC_END"
    } >> "$tmp"

    if ! mv -f "$tmp" "$rc_file"; then
        warn "could not write $rc_file"; rm -f "$tmp"; return 1
    fi
    say "Wired tokenwar/codex/gemini shell functions in $rc_file"
}

# Print the ids of every currently-enabled plugin, one per line (from
# `claude plugin list --json`). Empty on any failure.
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

# --with-plugins: register marketplaces, then install + enable the 4 plugins.
# Anti-clobber (gotcha 2026-05-18): the first `claude plugin enable` materialises
# enabledPlugins in settings.json and can flip implicitly-enabled plugins to
# disabled — so we snapshot the enabled set first and re-enable any that drop.
install_plugins() {
    if ! command -v "$CLAUDE_BIN" >/dev/null 2>&1; then
        warn "claude CLI not found — skipping --with-plugins. Install Claude Code, then re-run with --with-plugins (or use /tokenwar activate)."
        return 0
    fi
    say "Installing the stack's 4 Claude Code plugins (--with-plugins)"

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

# Wire RTK's hook. `rtk init -g` is non-interactive and patches settings.json
# itself. No-op (with a hint) when the binary isn't installed.
wire_rtk_hook() {
    if command -v "$RTK_BIN" >/dev/null 2>&1; then
        say "Wiring RTK hook (rtk init -g)"
        "$RTK_BIN" init -g >/dev/null 2>&1 || warn "rtk init -g failed — run it manually"
    else
        warn "rtk binary not found — install it with --with-rtk (or run \`rtk init -g\` after installing the RTK CLI)."
    fi
}

# --with-rtk: install the RTK binary, then wire its hook. RTK is a Rust binary,
# not a plugin, so it can't come from a plugin marketplace. Order of attempts:
#   1. already on PATH        → nothing to install.
#   2. rtk's OFFICIAL installer (prebuilt binary, every major platform, no
#      toolchain) — the fast, maintained path.
#   3. fallback: build from source with cargo; if cargo is missing, install the
#      Rust toolchain via rustup first. Only reached on platforms with no prebuilt.
install_rtk() {
    if command -v "$RTK_BIN" >/dev/null 2>&1; then
        say "RTK already installed ($("$RTK_BIN" --version 2>/dev/null || echo present)) — skipping install"
        return 0
    fi

    if command -v curl >/dev/null 2>&1; then
        say "Installing RTK via the official prebuilt installer ($RTK_INSTALL_REF)"
        curl -fsSL "$RTK_INSTALL_URL" | sh >/dev/null 2>&1 || warn "rtk official installer failed — will try cargo"
        # rtk drops the binary in ~/.local/bin; make it visible to this process.
        case ":$PATH:" in *":$RTK_LOCAL_BIN:"*) : ;; *) PATH="$RTK_LOCAL_BIN:$PATH" ;; esac
    else
        warn "curl not found — skipping prebuilt installer, trying cargo"
    fi

    if ! command -v "$RTK_BIN" >/dev/null 2>&1; then
        if ! command -v cargo >/dev/null 2>&1; then
            say "Installing the Rust toolchain (rustup) to build RTK from source"
            curl -fsSL "$RUSTUP_URL" | sh -s -- -y >/dev/null 2>&1 || warn "rustup install failed"
            # shellcheck disable=SC1091
            [[ -f "$HOME/.cargo/env" ]] && . "$HOME/.cargo/env"
        fi
        if command -v cargo >/dev/null 2>&1; then
            say "Building RTK from source ($RTK_GIT_URL)"
            cargo install --git "$RTK_GIT_URL" >/dev/null 2>&1 || warn "cargo install rtk failed"
            case ":$PATH:" in *":$HOME/.cargo/bin:"*) : ;; *) PATH="$HOME/.cargo/bin:$PATH" ;; esac
        fi
    fi

    command -v "$RTK_BIN" >/dev/null 2>&1 \
        && say "RTK installed ($("$RTK_BIN" --version 2>/dev/null || echo ok))." \
        || warn "RTK install failed — see https://github.com/rtk-ai/rtk for manual steps."
}

say "Wiring shell integration"
wired_any=false
for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
    if [[ -f "$rc" ]]; then
        wire_shell_rc "$rc" && wired_any=true
    fi
done
if ! $wired_any; then
    # No rc found — create ~/.bashrc so the integration lands somewhere.
    : > "$HOME/.bashrc"
    wire_shell_rc "$HOME/.bashrc" || warn "could not create shell integration in ~/.bashrc"
fi

# 5. plugins + rtk (opt-in)
if $WITH_PLUGINS; then install_plugins; fi
if $WITH_RTK; then install_rtk; fi
if $WITH_PLUGINS || $WITH_RTK; then wire_rtk_hook; fi

if $WITH_PLUGINS && $WITH_RTK; then
    next_steps="Plugins + RTK installed and RTK's hook wired. Restart Claude Code to load the plugins."
elif $WITH_PLUGINS; then
    next_steps="Plugins installed (restart Claude Code). RTK not installed — add --with-rtk, or install the RTK CLI and run \`rtk init -g\`."
elif $WITH_RTK; then
    next_steps="RTK installed + hook wired. Install the plugins with --with-plugins (or /tokenwar activate)."
else
    next_steps="Activate the tools (4 plugins incl. ponytail + the RTK hook) via the tokenwar skill:
  /tokenwar activate
(or re-run with --all to install everything in one shot)"
fi

cat <<EOF

$(green 'tokenwar installed.')

Sanity check now:
  bash $INSTALL_DIR/scripts/status.sh
  bash $INSTALL_DIR/scripts/check.sh
  bash $INSTALL_DIR/scripts/gain.sh

Statusline appears after restarting Claude Code.

Shell integration wired (reload your shell or 'source ~/.bashrc'):
  tokenwar status      # works in any shell — Codex, Gemini, plain terminal
  codex / gemini       # now print the tokenwar banner + upgrade prompt on launch

$next_steps

To uninstall:
  bash $INSTALL_DIR/uninstall.sh
EOF
