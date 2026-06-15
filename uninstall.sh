#!/usr/bin/env bash
# tokenwar uninstaller.
#
#   curl -fsSL https://raw.githubusercontent.com/oratelecom/tokenwar/main/uninstall.sh | bash
#
# Does:
#   1. remove statusLine from ~/.claude/settings.json (if it points at tokenwar)
#   2. remove ~/.claude/skills/tokenwar
#
# Does NOT touch:
#   - context-mode, claude-mem, caveman plugins (those are separate; remove with `claude plugin uninstall`)
#   - the RTK CLI or its hook (delete ~/.claude/hooks/rtk-rewrite.sh manually if wanted)
#   - settings.json backups created by install.sh (kept on purpose)

set -euo pipefail

INSTALL_DIR="${TOKENWAR_DIR:-$HOME/.claude/skills/tokenwar}"
SETTINGS_JSON="$HOME/.claude/settings.json"
STATUSLINE_CMD='bash ~/.claude/skills/tokenwar/scripts/tokenwar-statusline.sh'

readonly TW_RC_BEGIN="# >>> tokenwar shell integration >>>"
readonly TW_RC_END="# <<< tokenwar shell integration <<<"

color()  { printf '\033[%sm%s\033[0m' "$1" "$2"; }
green()  { color 32 "$1"; }
yellow() { color 33 "$1"; }
say()    { printf '%s %s\n' "$(green '==>')" "$*"; }
warn()   { printf '%s %s\n' "$(yellow '!!')" "$*" >&2; }

if [[ -f "$SETTINGS_JSON" ]]; then
    say "Unwiring statusLine from $SETTINGS_JSON"
    SETTINGS_JSON="$SETTINGS_JSON" STATUSLINE_CMD="$STATUSLINE_CMD" node --input-type=module -e '
import { readFileSync, writeFileSync, copyFileSync } from "fs";
const path = process.env.SETTINGS_JSON;
const desired = process.env.STATUSLINE_CMD;
let cfg = {};
try { cfg = JSON.parse(readFileSync(path, "utf8")); } catch { process.exit(0); }
if (cfg.statusLine && cfg.statusLine.command === desired) {
    const stamp = new Date().toISOString().replace(/[:.]/g, "-");
    copyFileSync(path, `${path}.bak-${stamp}`);
    delete cfg.statusLine;
    writeFileSync(path, JSON.stringify(cfg, null, 2) + "\n");
    console.log(`    removed statusLine (backup at ${path}.bak-${stamp})`);
} else {
    console.log("    statusLine not pointing at tokenwar — leaving settings.json alone");
}
'
else
    warn "$SETTINGS_JSON does not exist — skipping settings patch"
fi

# Strip the shell-integration block (tokenwar/codex/gemini functions) from rc.
unwire_shell_rc() {
    local rc_file="$1"
    [[ -f "$rc_file" ]] || return 0
    grep -qF "$TW_RC_BEGIN" "$rc_file" 2>/dev/null || return 0
    local tmp
    tmp="$(mktemp "${rc_file}.tokenwar.XXXXXX")" || { warn "mktemp failed for $rc_file"; return 1; }
    TW_BEGIN="$TW_RC_BEGIN" TW_END="$TW_RC_END" awk '
        $0 == ENVIRON["TW_BEGIN"] { skip = 1 }
        skip != 1 { print }
        $0 == ENVIRON["TW_END"]   { skip = 0 }
    ' "$rc_file" > "$tmp" || { warn "could not rewrite $rc_file"; rm -f "$tmp"; return 1; }
    if mv -f "$tmp" "$rc_file"; then
        say "Removed tokenwar shell integration from $rc_file"
    else
        warn "could not write $rc_file"; rm -f "$tmp"; return 1
    fi
}

say "Removing shell integration"
for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
    unwire_shell_rc "$rc"
done

if [[ -d "$INSTALL_DIR" ]]; then
    say "Removing $INSTALL_DIR"
    rm -rf "$INSTALL_DIR"
else
    warn "$INSTALL_DIR does not exist — already removed"
fi

cat <<EOF

$(green 'tokenwar uninstalled.')

Restart Claude Code to drop the statusline.

The 5 tools tokenwar orchestrates remain installed. Remove them yourself if wanted:
  claude plugin uninstall context-mode@context-mode
  claude plugin uninstall claude-mem@thedotmack
  claude plugin uninstall caveman@caveman
  claude plugin uninstall ponytail@ponytail
  rm ~/.claude/hooks/rtk-rewrite.sh   # also remove PreToolUse hook from settings.json
EOF
