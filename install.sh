#!/usr/bin/env bash
# tokenwar one-shot installer.
#
#   curl -fsSL https://raw.githubusercontent.com/oratelecom/tokenwar/main/install.sh | bash
#
# Does:
#   1. git clone https://github.com/oratelecom/tokenwar ~/.claude/skills/tokenwar
#   2. chmod +x scripts/*.sh
#   3. patch ~/.claude/settings.json to wire the statusLine
#   4. print next-step instructions (install plugins, etc.)
#
# Idempotent: re-running pulls the latest tokenwar and only patches settings.json
# if the statusLine is not already pointing at the tokenwar script.

set -euo pipefail

REPO_URL="${TOKENWAR_REPO_URL:-https://github.com/oratelecom/tokenwar}"
INSTALL_DIR="${TOKENWAR_DIR:-$HOME/.claude/skills/tokenwar}"
SETTINGS_JSON="$HOME/.claude/settings.json"
STATUSLINE_CMD='bash ~/.claude/skills/tokenwar/scripts/tokenwar-statusline.sh'

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

Activate the other three tools and the RTK hook via the tokenwar skill:
  /tokenwar activate

To uninstall:
  bash $INSTALL_DIR/uninstall.sh
EOF
