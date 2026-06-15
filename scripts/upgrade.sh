#!/usr/bin/env bash
# tokenwar upgrade — bump the 4 token-saving tools to their latest versions.
#
# Plugins (context-mode, claude-mem, caveman) → `claude plugin update <slug> --scope <scope>`.
# RTK (path-installed dev build)              → `cargo install --path <repo> --force`.
#
# Source of "what needs updating": the throttled upgrade-check cache written by
# check-updates.sh. If the cache is absent, all four are attempted. The cache is
# never refreshed here (no network) — pass the cache as authoritative.
#
# Usage:
#   upgrade.sh            # interactive: confirm before applying
#   upgrade.sh --yes      # non-interactive: apply without prompting
#   upgrade.sh --all      # ignore cache, attempt all four
#
# Exit: 0 on success (or nothing to do), 1 if any upgrade command failed.

set -uo pipefail

readonly SLUG_CTX="context-mode@context-mode"
readonly SLUG_MEM="claude-mem@thedotmack"
readonly SLUG_CAVE="caveman@caveman"

readonly CLAUDE_BIN="claude"
readonly CARGO_BIN="cargo"

readonly UPGRADE_CACHE_FILE="${HOME}/.claude/tokenwar/upgrade-check.json"
readonly STATE_UPDATE="update-available"

readonly COL_GREEN=$'\033[32m'
readonly COL_RED=$'\033[31m'
readonly COL_YELLOW=$'\033[33m'
readonly COL_DIM=$'\033[2m'
readonly COL_RESET=$'\033[0m'

assume_yes=false
force_all=false
for arg in "$@"; do
    case "$arg" in
        --yes) assume_yes=true ;;
        --all) force_all=true ;;
        *) echo "unknown arg: $arg" >&2; exit 2 ;;
    esac
done

say()  { printf '%s %s\n' "${COL_GREEN}==>${COL_RESET}" "$*"; }
warn() { printf '%s %s\n' "${COL_YELLOW}!!${COL_RESET}" "$*" >&2; }
fail() { printf '%s %s\n' "${COL_RED}ERR${COL_RESET}" "$*" >&2; }

# True only if /dev/tty can actually be opened (a controlling terminal exists).
# The inner redirection's failure is swallowed by the group-level 2>/dev/null,
# so probing never leaks "No such device or address".
tty_readable() { { : </dev/tty; } 2>/dev/null; }

# Which tools have an update? Echoes space-separated tool keys (ctx mem cave rtk).
# Reads the cache; with --all or no cache, returns all four.
tools_needing_update() {
    if $force_all || [[ ! -f "$UPGRADE_CACHE_FILE" ]]; then
        echo "ctx mem cave rtk"; return
    fi
    CACHE="$UPGRADE_CACHE_FILE" TW_STATE="$STATE_UPDATE" node --input-type=module -e '
        import { readFileSync } from "node:fs";
        let d; try { d = JSON.parse(readFileSync(process.env.CACHE, "utf8")); } catch { console.log("ctx mem cave rtk"); process.exit(0); }
        const t = d.tools || {};
        const want = process.env.TW_STATE;
        const map = { "context-mode": "ctx", "claude-mem": "mem", "caveman": "cave", "rtk": "rtk" };
        const out = [];
        for (const [name, key] of Object.entries(map)) {
            if (t[name] && t[name].state === want) out.push(key);
        }
        console.log(out.join(" "));
    ' 2>/dev/null || echo "ctx mem cave rtk"
}

# Look up a plugin's install scope (user|local|project|managed) from
# `claude plugin list --json`. Empty if unknown. Needed because `plugin update`
# defaults to user scope and fails on a plugin installed at another scope
# (e.g. claude-mem is commonly installed `local`).
plugin_scope() {
    "$CLAUDE_BIN" plugin list --json 2>/dev/null | PLUGIN_QUERY="$1" node --input-type=module -e '
        let s = "";
        process.stdin.on("data", d => s += d).on("end", () => {
            let arr = []; try { arr = JSON.parse(s || "[]"); } catch {}
            const e = arr.find(p => p && p.id === process.env.PLUGIN_QUERY);
            if (e && e.scope) console.log(e.scope);
        });
    ' 2>/dev/null || true
}

# Upgrade one plugin via the Claude CLI. Returns non-zero on failure.
upgrade_plugin() {
    local slug="$1"
    if ! command -v "$CLAUDE_BIN" >/dev/null 2>&1; then
        warn "claude CLI not found — cannot update $slug"; return 1
    fi
    say "Updating plugin $slug"
    local scope
    scope="$(plugin_scope "$slug")"
    if [[ -n "$scope" ]]; then
        "$CLAUDE_BIN" plugin update "$slug" --scope "$scope"
    else
        "$CLAUDE_BIN" plugin update "$slug"
    fi
}

# Upgrade RTK. Only the path-installed dev build is supported (the public crate
# name belongs to a different project). Discover the repo from cargo's install
# list; if not path-installed, skip with a note rather than touching the wrong
# crate.
upgrade_rtk() {
    if ! command -v "$CARGO_BIN" >/dev/null 2>&1; then
        warn "cargo not found — cannot update RTK"; return 1
    fi
    local repo_path
    repo_path=$("$CARGO_BIN" install --list 2>/dev/null \
        | awk '/^rtk v.* \(.*\):$/ { match($0, /\(([^)]+)\)/, m); print m[1]; exit }')
    if [[ -z "$repo_path" || ! -d "$repo_path/.git" ]]; then
        warn "RTK is not path-installed — skipping (registry crate is a different project)"
        return 0
    fi
    say "Updating RTK from $repo_path"
    git -C "$repo_path" pull --ff-only && "$CARGO_BIN" install --path "$repo_path" --force
}

# === collect work ===
read -r -a needing <<<"$(tools_needing_update)"
if (( ${#needing[@]} == 0 )); then
    say "All tools up-to-date — nothing to upgrade."
    exit 0
fi

echo ""
echo "${COL_YELLOW}tokenwar upgrade${COL_RESET} — the following tools will be updated:"
for key in "${needing[@]}"; do
    case "$key" in
        ctx)  printf "  %s\n" "context-mode" ;;
        mem)  printf "  %s\n" "claude-mem" ;;
        cave) printf "  %s\n" "caveman" ;;
        rtk)  printf "  %s\n" "rtk" ;;
    esac
done
echo ""

# === confirm ===
if ! $assume_yes; then
    reply=""
    if tty_readable; then
        printf "Upgrade now? [y/N] "
        read -r reply </dev/tty 2>/dev/null || reply=""
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
rc=0
for key in "${needing[@]}"; do
    case "$key" in
        ctx)  upgrade_plugin "$SLUG_CTX"  || rc=1 ;;
        mem)  upgrade_plugin "$SLUG_MEM"  || rc=1 ;;
        cave) upgrade_plugin "$SLUG_CAVE" || rc=1 ;;
        rtk)  upgrade_rtk                 || rc=1 ;;
    esac
done

echo ""
if (( rc == 0 )); then
    say "Upgrade complete. ${COL_DIM}Restart your CLI for plugin changes to load.${COL_RESET}"
else
    fail "One or more upgrades failed — see messages above."
fi
exit "$rc"
