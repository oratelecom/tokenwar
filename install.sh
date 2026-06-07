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

cat <<EOF

$(green 'tokenwar installed.')

Sanity check now:
  bash $INSTALL_DIR/scripts/status.sh
  bash $INSTALL_DIR/scripts/check.sh
  bash $INSTALL_DIR/scripts/gain.sh

Statusline appears after restarting Claude Code.

Activate the other three tools and the RTK hook via the tokenwar skill:
  /tokenwar activate

To uninstall:
  bash $INSTALL_DIR/uninstall.sh
EOF
