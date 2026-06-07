#!/usr/bin/env bash
# tokenwar restore-settings — merge ~/.claude/settings.local.json INTO
# ~/.claude/settings.json. Run before `claude` if Claude Code wiped your
# settings on session start (known regression with new model migrations).
#
# Strategy: take the current settings.json (whatever Claude Code wrote),
# overlay every top-level key from settings.local.json. local.json wins.
# This preserves any new key Claude Code added (e.g. migration flags)
# while restoring our enabledPlugins / hooks / statusLine.

set -euo pipefail

readonly SETTINGS="${HOME}/.claude/settings.json"
readonly LOCAL="${HOME}/.claude/settings.local.json"
readonly BACKUP="${SETTINGS}.tokenwar-bak"

if [[ ! -f "$LOCAL" ]]; then
    echo "[tokenwar restore] no settings.local.json at $LOCAL — nothing to merge" >&2
    exit 1
fi

if [[ ! -f "$SETTINGS" ]]; then
    echo "[tokenwar restore] settings.json missing — copying local as fresh"
    cp "$LOCAL" "$SETTINGS"
    chmod 600 "$SETTINGS"
    exit 0
fi

cp -f "$SETTINGS" "$BACKUP"

SETTINGS_PATH="$SETTINGS" LOCAL_PATH="$LOCAL" node --input-type=module -e '
    import { readFileSync, writeFileSync } from "fs";
    const cur   = JSON.parse(readFileSync(process.env.SETTINGS_PATH, "utf8"));
    const local = JSON.parse(readFileSync(process.env.LOCAL_PATH,    "utf8"));
    const merged = { ...cur, ...local };  // local wins on conflict
    writeFileSync(process.env.SETTINGS_PATH, JSON.stringify(merged, null, 2) + "\n", "utf8");
    const restored = Object.keys(local).filter(k => !cur[k]);
    console.log("[tokenwar restore] restored keys:", restored.length ? restored.join(", ") : "(all present, no-op)");
'
