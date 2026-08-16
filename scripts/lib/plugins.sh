#!/usr/bin/env bash
# Shared Claude Code plugin-state loader.
#
# Primary source of truth is `claude plugin list --json` — it reports what is
# installed AND each plugin's `enabled` bit in one shot, and is what the test
# harness mocks. When the CLI yields no usable JSON array (old CLI without the
# subcommand, or `claude` not on PATH), fall back to on-disk config:
#   - installed_plugins.json  → what is installed
#   - enabledPlugins OR-merged from settings.json AND settings.local.json
#     → the enabled/disabled bit (Claude Code merges both files at runtime, so a
#     plugin enabled only in the local file must not read as disabled).
# An installed plugin absent from enabledPlugins is enabled by default (Claude
# semantics); an explicit `false` stays disabled — we never coerce to enabled,
# which would hide `installed-disabled`.
#
# Config dir is overridable via CLAUDE_CONFIG_DIR (tests, relocated ~/.claude).
# The claude binary is overridable via TW_CLAUDE_BIN (defaults to `claude`).

# tw_load_plugin_list — echo a JSON array of {id, enabled, version}.
tw_load_plugin_list() {
    local claude_bin="${TW_CLAUDE_BIN:-claude}"

    # 1. Primary: the claude CLI (authoritative + mockable).
    local cli_out
    cli_out="$("$claude_bin" plugin list --json 2>/dev/null)"
    if [[ -n "$cli_out" ]] \
        && node -e "const a=JSON.parse(process.argv[1]);process.exit(Array.isArray(a)&&a.length?0:1)" "$cli_out" 2>/dev/null; then
        printf '%s' "$cli_out"
        return
    fi

    # 2. Fallback: derive from on-disk config when the CLI cannot answer.
    local config_dir="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}"
    local installed_file="${config_dir}/plugins/installed_plugins.json"
    if [[ ! -f "$installed_file" ]]; then
        printf '[]'
        return
    fi

    INSTALLED_FILE="$installed_file" \
    SETTINGS_FILE="${config_dir}/settings.json" \
    SETTINGS_LOCAL_FILE="${config_dir}/settings.local.json" \
    node --input-type=module -e '
        import { readFileSync } from "node:fs";
        const read = f => { try { return JSON.parse(readFileSync(f, "utf8")); } catch { return null; } };
        const installed = read(process.env.INSTALLED_FILE) || {};
        const enabledMap = {
            ...((read(process.env.SETTINGS_FILE) || {}).enabledPlugins || {}),
            ...((read(process.env.SETTINGS_LOCAL_FILE) || {}).enabledPlugins || {}),
        };
        const out = [];
        for (const [id, installs] of Object.entries(installed.plugins || {})) {
            if (!Array.isArray(installs) || installs.length === 0) continue;
            const enabled = id in enabledMap ? Boolean(enabledMap[id]) : true;
            out.push({ id, enabled, version: installs[0].version || "unknown" });
        }
        console.log(JSON.stringify(out));
    ' 2>/dev/null || printf '[]'
}
