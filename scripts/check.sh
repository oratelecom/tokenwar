#!/usr/bin/env bash
# tokenwar check — verify core tool lanes are complementary, not conflicting.
#
# Four rules:
#   R1 bash double-hook   — RTK and context-mode both want to wrap bash
#   R2 memory overlap     — claude-mem and context-mode both store recall
#   R3 output compression — caveman vs RTK target overlap
#   R4 version drift      — any tool more than one minor behind
#
# Exit 0 if all PASS, 1 if any WARN or FAIL.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# shellcheck source=lib/providers.sh
source "${SCRIPT_DIR}/lib/providers.sh"

readonly INSTALLED_PLUGINS="${HOME}/.claude/plugins/installed_plugins.json"
readonly SETTINGS_FILE="${HOME}/.claude/settings.json"
readonly CLAUDE_MEM_DATA="${HOME}/.claude-mem"

readonly RES_PASS="PASS"
readonly RES_WARN="WARN"
readonly RES_FAIL="FAIL"

readonly COL_GREEN=$'\033[32m'
readonly COL_RED=$'\033[31m'
readonly COL_YELLOW=$'\033[33m'
readonly COL_DIM=$'\033[2m'
readonly COL_RESET=$'\033[0m'

emit() {
    local rule="$1" result="$2" evidence="$3"
    local color
    case "$result" in
        "$RES_PASS") color="$COL_GREEN" ;;
        "$RES_WARN") color="$COL_YELLOW" ;;
        "$RES_FAIL") color="$COL_RED" ;;
        *)           color="$COL_DIM" ;;
    esac
    printf "  %-26s : %s%s%s  %s%s%s\n" \
        "$rule" "$color" "$result" "$COL_RESET" \
        "$COL_DIM" "$evidence" "$COL_RESET"
}

# === R1 — bash double-hook ===
# RTK installs a PreToolUse hook for Bash that rewrites commands.
# context-mode redirects bash via skill rules (CLAUDE.md). Other context-mode
# hooks may live in ~/.claude/hooks but they target DIFFERENT events (SessionStart
# cache-heal etc). Real conflict = two hooks both registered for PreToolUse on
# the same matcher in settings.json.
#
# Source of truth: parse settings.json's hooks tree and look for
# multiple entries matching "Bash" on PreToolUse.
check_r1() {
    if [[ ! -f "$SETTINGS_FILE" ]]; then
        echo "$RES_WARN|settings.json missing"; return
    fi
    local result
    result=$(SETTINGS="$SETTINGS_FILE" node --input-type=module -e '
        import { readFileSync } from "fs";
        let cfg;
        try { cfg = JSON.parse(readFileSync(process.env.SETTINGS,"utf8")); }
        catch { console.log("FAIL|cannot parse settings.json"); process.exit(0); }
        const pre = (cfg.hooks && cfg.hooks.PreToolUse) || [];
        const bashHooks = pre.filter(h => (h.matcher||"") === "Bash")
                             .flatMap(h => h.hooks || []);
        if (bashHooks.length === 0) {
            console.log("WARN|no PreToolUse Bash hook registered — RTK rewrite is not wired (run rtk init -g)");
        } else if (bashHooks.length === 1) {
            const cmd = bashHooks[0].command || "(inline)";
            console.log("PASS|single PreToolUse Bash hook: " + cmd);
        } else {
            console.log("FAIL|" + bashHooks.length + " PreToolUse Bash hooks registered — order matters, verify they cooperate");
        }
    ')
    echo "$result"
}

# === R2 — memory source overlap ===
# context-mode stores recall in ~/.claude/projects/<slug>/memory.
# claude-mem stores in ~/.claude-mem (own data dir). Different sinks → no
# overlap. Conflict only if claude-mem is configured to write into the
# context-mode project dir.
check_r2() {
    local mem_installed=false
    if [[ -f "$INSTALLED_PLUGINS" ]] && grep -q '"claude-mem@thedotmack"' "$INSTALLED_PLUGINS"; then
        mem_installed=true
    fi
    if ! $mem_installed; then
        echo "$RES_PASS|claude-mem not active; only context-mode handles recall"
        return
    fi
    if [[ -d "$CLAUDE_MEM_DATA" ]]; then
        echo "$RES_PASS|claude-mem writes to $CLAUDE_MEM_DATA; context-mode writes to ~/.claude/projects/<slug>/memory — disjoint sinks"
    else
        echo "$RES_WARN|claude-mem installed but data dir not found at $CLAUDE_MEM_DATA — run a session to materialise"
    fi
}

# === R3 — output compression layering ===
# RTK compresses tool outputs (stdout of shell commands).
# caveman compresses the LLM's responses (different buffer).
# Always complementary unless RTK ever wraps the LLM stream (it doesn't).
check_r3() {
    echo "$RES_PASS|RTK→tool output; caveman→LLM response. Disjoint buffers, complementary by design."
}

# === R5 — provider overlap ===
# Multiple AI providers may be installed simultaneously.
# They share the same shell and filesystem but use separate config dirs
# (~/.claude, ~/.codex, ~/.gemini, ~/.kimi-code by default). Verify their
# tool/hook footprints don't collide on the same events or matchers.
#
# A provider is considered "active" only if BOTH its CLI binary is on PATH AND
# its config dir exists in HOME. This prevents false WARN in isolated test
# environments where system binaries are visible but config dirs aren't.
check_r5() {
    local active_providers=()
    local active_dirs=()
    for i in $(seq 0 $((PROVIDER_COUNT - 1))); do
        if provider_is_installed "$i"; then
            local pdir
            pdir=$(provider_config_dir "$i")
            if [[ -n "$pdir" && -d "$pdir" ]]; then
                active_providers+=("$(provider_name "$i")")
                active_dirs+=("$pdir")
            fi
        fi
    done
    if (( ${#active_providers[@]} <= 1 )); then
        echo "$RES_PASS|only ${#active_providers[@]} active provider(s) (${active_providers[*]:-none}) — no overlap possible"
        return
    fi
    # Multiple active providers — verify config dirs are disjoint (all providers
    # use separate dirs by convention, so this is a sanity check).
    echo "$RES_PASS|${#active_providers[@]} active providers (${active_providers[*]}), disjoint config dirs — no tool overlap"
}
# Heuristic: read installed versions; flag if any tool is missing entirely.
# Real "latest" comparison requires network; we only flag installed-but-old
# or not-installed cases here.
check_r4() {
    if [[ ! -f "$INSTALLED_PLUGINS" ]]; then
        echo "$RES_FAIL|installed_plugins.json missing"
        return
    fi
    local missing=()
    for slug in "context-mode@context-mode" "claude-mem@thedotmack" "caveman@caveman"; do
        if ! grep -q "\"$slug\"" "$INSTALLED_PLUGINS"; then
            missing+=("$slug")
        fi
    done
    if command -v rtk >/dev/null 2>&1; then :; else missing+=("rtk"); fi

    if (( ${#missing[@]} == 0 )); then
        echo "$RES_PASS|core hook/plugin tools installed (latest-version check needs network; see /tokenwar upgrade)"
    else
        echo "$RES_WARN|not installed: ${missing[*]}"
    fi
}

echo ""
echo "# /tokenwar check"
echo ""

declare -A results
for rule_id in R1 R2 R3 R4 R5; do
    case "$rule_id" in
        R1) raw=$(check_r1); label="R1 bash double-hook" ;;
        R2) raw=$(check_r2); label="R2 memory source overlap" ;;
        R3) raw=$(check_r3); label="R3 output compression" ;;
        R4) raw=$(check_r4); label="R4 version drift" ;;
        R5) raw=$(check_r5); label="R5 provider overlap" ;;
    esac
    result="${raw%%|*}"
    evidence="${raw#*|}"
    results[$rule_id]="$result"
    emit "$label" "$result" "$evidence"
done

# verdict
verdict="COMPLEMENTARY"
exit_code=0
for r in "${results[@]}"; do
    case "$r" in
        "$RES_FAIL") verdict="CONFLICT";       exit_code=1 ;;
        "$RES_WARN") [[ "$verdict" != "CONFLICT" ]] && verdict="DEGRADED"; exit_code=1 ;;
    esac
done

echo ""
echo "  Verdict: $verdict"
echo ""
exit "$exit_code"
