#!/usr/bin/env bash
# tokenwar check-updates — detect available upgrades for the 4-tool stack.
#
# Strategy: refresh marketplace manifests (throttled, 24h cache), then compare
# installed version vs marketplace `version` field for each plugin. For RTK,
# compare local `rtk --version` against `cargo search rtk` registry result.
#
# Output: one line per tool with status `up-to-date | update-available | ahead | unknown`.
# Exit codes: 0 = all up-to-date, 2 = at least one update available, 1 = error.
#
# Cache: ~/.claude/tokenwar/upgrade-check.json — refreshed when older than CACHE_TTL_SECONDS.
# Force refresh: pass --force.

set -euo pipefail

readonly CACHE_DIR="${HOME}/.claude/tokenwar"
readonly CACHE_FILE="${CACHE_DIR}/upgrade-check.json"
readonly CACHE_TTL_SECONDS=86400  # 24h

readonly SLUG_CTX="context-mode@context-mode"
readonly SLUG_MEM="claude-mem@thedotmack"
readonly SLUG_CAVE="caveman@caveman"

readonly MARKETPLACE_CTX="context-mode"
readonly MARKETPLACE_MEM="thedotmack"
readonly MARKETPLACE_CAVE="caveman"

readonly MARKETPLACE_ROOT="${HOME}/.claude/plugins/marketplaces"
readonly MARKETPLACE_MANIFEST_REL=".claude-plugin/marketplace.json"
readonly RTK_BIN="rtk"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
# shellcheck source=lib/providers.sh
source "${SCRIPT_DIR}/lib/providers.sh"

readonly STATUS_UPTODATE="up-to-date"
readonly STATUS_UPDATE="update-available"
readonly STATUS_AHEAD="ahead"
readonly STATUS_UNKNOWN="unknown"

force_refresh=false
quiet=false
for arg in "$@"; do
    case "$arg" in
        --force) force_refresh=true ;;
        --quiet) quiet=true ;;
        *) echo "unknown arg: $arg" >&2; exit 1 ;;
    esac
done

mkdir -p "$CACHE_DIR"

cache_is_fresh() {
    [[ -f "$CACHE_FILE" ]] || return 1
    local now mtime age
    now=$(date +%s)
    mtime=$(stat -c %Y "$CACHE_FILE" 2>/dev/null || stat -f %m "$CACHE_FILE" 2>/dev/null || echo 0)
    age=$((now - mtime))
    (( age < CACHE_TTL_SECONDS ))
}

# Refresh marketplaces (network call). Per-marketplace `git fetch` only — we
# read the latest `marketplace.json` from the fetched upstream ref
# (`marketplace_version` below), so we never `git pull`/`git checkout` and never
# need a clean working tree. This is critical: a locally-customized clone (e.g.
# a `plugin.json` rewritten to point at a bun binary + absolute paths) would
# make `git pull --ff-only` fail forever and poison the cache with phantom
# "up-to-date" verdicts. Failures are surfaced on stderr (unless --quiet) but
# never abort — we still emit a cache below, and the global `refresh_ok` flag
# tells consumers the cache may be stale.
#
# We intentionally do NOT call `claude plugin marketplace update` here: it
# races against the subsequent `claude plugin list --json` invocations (the
# CLI briefly returns an empty list while it rewrites its registry).
readonly REFRESHABLE_MARKETPLACES=(
    "$MARKETPLACE_CTX"
    "$MARKETPLACE_MEM"
    "$MARKETPLACE_CAVE"
)
refresh_marketplaces() {
    local mp dir rc=0
    for mp in "${REFRESHABLE_MARKETPLACES[@]}"; do
        dir="${MARKETPLACE_ROOT}/${mp}"
        if [[ ! -d "${dir}/.git" ]]; then
            $quiet || echo "tokenwar: marketplace clone missing: $dir" >&2
            rc=1
            continue
        fi
        if ! git -C "$dir" fetch --quiet 2>/dev/null; then
            $quiet || echo "tokenwar: git fetch failed for marketplace '$mp'" >&2
            rc=1
            continue
        fi
    done
    return $rc
}

# Read `version` from a marketplace.json's plugins[] entry matching `name`.
# Reads the manifest from the fetched upstream ref (origin/<branch>) first, so
# a clone that is behind upstream — or has local working-tree edits — never
# reports a stale "latest". Falls back to the on-disk manifest (no upstream),
# then to the upstream/local short git SHA when the manifest carries no
# `version` field — caveman, e.g., versions by SHA only.
readonly MARKETPLACE_GIT_SHA_LEN=12
marketplace_version() {
    local marketplace="$1" plugin_name="$2"
    local marketplace_dir="${MARKETPLACE_ROOT}/${marketplace}"
    local upstream="" manifest_json="" v=""

    if [[ -d "${marketplace_dir}/.git" ]]; then
        upstream=$(git -C "$marketplace_dir" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || echo "")
        if [[ -n "$upstream" ]]; then
            manifest_json=$(git -C "$marketplace_dir" show "${upstream}:${MARKETPLACE_MANIFEST_REL}" 2>/dev/null || echo "")
        fi
    fi
    if [[ -z "$manifest_json" && -f "${marketplace_dir}/${MARKETPLACE_MANIFEST_REL}" ]]; then
        manifest_json=$(cat "${marketplace_dir}/${MARKETPLACE_MANIFEST_REL}" 2>/dev/null || echo "")
    fi
    if [[ -n "$manifest_json" ]]; then
        v=$(MANIFEST_JSON="$manifest_json" PLUGIN_NAME="$plugin_name" node --input-type=module -e "
            const m = JSON.parse(process.env.MANIFEST_JSON);
            const list = Array.isArray(m.plugins) ? m.plugins : [];
            const entry = list.find(p => p.name === process.env.PLUGIN_NAME);
            process.stdout.write(entry?.version || '');
        " 2>/dev/null || echo "")
        if [[ -n "$v" ]]; then echo "$v"; return; fi
    fi
    if [[ -d "${marketplace_dir}/.git" ]]; then
        git -C "$marketplace_dir" rev-parse --short="$MARKETPLACE_GIT_SHA_LEN" "${upstream:-HEAD}" 2>/dev/null || echo ""
        return
    fi
    echo ""
}

installed_plugin_version() {
    local slug="$1"
    PLUGIN_QUERY="$slug" node --input-type=module -e "
        import { execSync } from 'node:child_process';
        const out = execSync('claude plugin list --json', { encoding: 'utf8' });
        const arr = JSON.parse(out || '[]');
        const entry = arr.find(p => p.id === process.env.PLUGIN_QUERY);
        process.stdout.write(entry?.version || '');
    " 2>/dev/null || echo ""
}

rtk_installed_version() {
    command -v "$RTK_BIN" >/dev/null 2>&1 || { echo ""; return; }
    "$RTK_BIN" --version 2>/dev/null | awk '{print $2}'
}

# Determine rtk's authoritative latest version.
#
# Two install paths exist:
#   1. Path-installed (`cargo install --path /path/to/rtk` — dev build). The
#      installed `rtk` binary was built from a local clone; latest = the
#      `version` field in that clone's Cargo.toml on the tracked upstream
#      branch. We `git fetch` first, then read `origin/<branch>:Cargo.toml`
#      so a stale local checkout doesn't shadow upstream.
#   2. Registry-installed. Fall back to `cargo search`, but the public
#      registry name `rtk` belongs to a different crate (Rust Type Kit);
#      results are unreliable. Return empty in that case.
rtk_latest_version() {
    command -v cargo >/dev/null 2>&1 || { echo ""; return; }
    local repo_path
    repo_path=$(cargo install --list 2>/dev/null \
        | awk '/^rtk v.* \(.*\):$/ { match($0, /\(([^)]+)\)/, m); print m[1]; exit }')
    if [[ -n "$repo_path" && -d "$repo_path/.git" ]]; then
        git -C "$repo_path" fetch --quiet 2>/dev/null || true
        local branch ref
        branch=$(git -C "$repo_path" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || echo "")
        ref="${branch:-HEAD}"
        git -C "$repo_path" show "${ref}:Cargo.toml" 2>/dev/null \
            | awk -F'"' '/^version[[:space:]]*=/ {print $2; exit}'
        return
    fi
    echo ""
}

# Compare two version strings. Returns one of: up-to-date | update-available | ahead | unknown.
#   - Equal → up-to-date
#   - Both parseable semver and installed < latest → update-available
#   - Both parseable semver and installed > latest → ahead (dev build)
#   - Otherwise (SHA, missing field) → up-to-date if equal, else update-available
classify() {
    local installed="$1" latest="$2"
    if [[ -z "$installed" || -z "$latest" ]]; then
        echo "$STATUS_UNKNOWN"; return
    fi
    if [[ "$installed" == "$latest" ]]; then
        echo "$STATUS_UPTODATE"; return
    fi
    # semver compare
    if [[ "$installed" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$latest" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        local cmp
        cmp=$(printf '%s\n%s\n' "$installed" "$latest" | sort -V | head -1)
        if [[ "$cmp" == "$installed" ]]; then
            echo "$STATUS_UPDATE"
        else
            echo "$STATUS_AHEAD"
        fi
        return
    fi
    # non-semver (git SHA, etc.) — different strings means update assumed
    echo "$STATUS_UPDATE"
}

if $force_refresh || ! cache_is_fresh; then
    refresh_ok=true
    refresh_marketplaces || refresh_ok=false

    ctx_installed=$(installed_plugin_version "$SLUG_CTX")
    mem_installed=$(installed_plugin_version "$SLUG_MEM")
    cave_installed=$(installed_plugin_version "$SLUG_CAVE")
    rtk_installed=$(rtk_installed_version)

    # Provider CLI versions
    codex_installed=$(provider_version "$PROVIDER_IDX_CODEX")
    gemini_installed=$(provider_version "$PROVIDER_IDX_GEMINI")
    kimi_installed=$(provider_version "$PROVIDER_IDX_KIMI")
    # Latest provider versions: we don't have a reliable upstream source yet
    # (npm view would require knowing the exact package name). For now,
    # installed == latest unless we can prove otherwise via `codex doctor`.
    codex_latest="$codex_installed"
    gemini_latest="$gemini_installed"
    kimi_latest="$kimi_installed"
    # Codex self-reports updates via `codex doctor` — parse if available
    if command -v codex >/dev/null 2>&1 && [[ -n "$codex_installed" ]]; then
        codex_doctor_latest=$(codex doctor 2>/dev/null | awk '/updates available/ {print $2}' | head -1 || echo "")
        [[ -n "$codex_doctor_latest" ]] && codex_latest="$codex_doctor_latest"
    fi
    ctx_latest=$(marketplace_version "$MARKETPLACE_CTX" "context-mode")
    mem_latest=$(marketplace_version "$MARKETPLACE_MEM" "claude-mem")
    cave_latest=$(marketplace_version "$MARKETPLACE_CAVE" "caveman")
    rtk_latest=$(rtk_latest_version)

    ctx_state=$(classify "$ctx_installed" "$ctx_latest")
    mem_state=$(classify "$mem_installed" "$mem_latest")
    cave_state=$(classify "$cave_installed" "$cave_latest")
    rtk_state=$(classify "$rtk_installed" "$rtk_latest")
    codex_state=$(classify "$codex_installed" "$codex_latest")
    gemini_state=$(classify "$gemini_installed" "$gemini_latest")
    kimi_state=$(classify "$kimi_installed" "$kimi_latest")

    now=$(date +%s)
    TOKENWAR_CACHE_FILE="$CACHE_FILE" \
    NOW="$now" \
    REFRESH_OK="$($refresh_ok && echo 1 || echo 0)" \
    CTX_I="$ctx_installed" CTX_L="$ctx_latest" CTX_S="$ctx_state" \
    MEM_I="$mem_installed" MEM_L="$mem_latest" MEM_S="$mem_state" \
    CAVE_I="$cave_installed" CAVE_L="$cave_latest" CAVE_S="$cave_state" \
    RTK_I="$rtk_installed" RTK_L="$rtk_latest" RTK_S="$rtk_state" \
    CODEX_I="$codex_installed" CODEX_L="$codex_latest" CODEX_S="$codex_state" \
    GEMINI_I="$gemini_installed" GEMINI_L="$gemini_latest" GEMINI_S="$gemini_state" \
    KIMI_I="$kimi_installed" KIMI_L="$kimi_latest" KIMI_S="$kimi_state" \
    node --input-type=module -e "
        import { writeFileSync } from 'node:fs';
        const e = process.env;
        const data = {
            checked_at: Number(e.NOW),
            refresh_ok: e.REFRESH_OK === '1',
            tools: {
                'context-mode': { installed: e.CTX_I, latest: e.CTX_L, state: e.CTX_S, slug: '$SLUG_CTX' },
                'claude-mem':   { installed: e.MEM_I, latest: e.MEM_L, state: e.MEM_S, slug: '$SLUG_MEM' },
                'caveman':      { installed: e.CAVE_I, latest: e.CAVE_L, state: e.CAVE_S, slug: '$SLUG_CAVE' },
                'rtk':          { installed: e.RTK_I, latest: e.RTK_L, state: e.RTK_S, slug: 'cargo:rtk' }
            },
            providers: {
                'codex':  { installed: e.CODEX_I, latest: e.CODEX_L, state: e.CODEX_S },
                'gemini': { installed: e.GEMINI_I, latest: e.GEMINI_L, state: e.GEMINI_S },
                'kimi':   { installed: e.KIMI_I, latest: e.KIMI_L, state: e.KIMI_S }
            }
        };
        writeFileSync(e.TOKENWAR_CACHE_FILE, JSON.stringify(data, null, 2));
    "
fi

# Render cache → stdout (unless --quiet, in which case only set exit code).
_render_cache() {
    local cache_file="$1" quiet="$2" status_upd_val="$3"
    TWC_QUIET="$quiet" TWC_STAT_UPD="$status_upd_val" TWC_CACHE_FILE="$cache_file" node --input-type=module <<'NODESCRIPT'
import { readFileSync } from 'node:fs';

const data = JSON.parse(readFileSync(process.env.TWC_CACHE_FILE, 'utf8'));
const toolEntries = Object.entries(data.tools);
const providerEntries = data.providers ? Object.entries(data.providers) : [];
const allEntries = [...toolEntries, ...providerEntries];
const updates = allEntries.filter(([, v]) => v.state === process.env.TWC_STAT_UPD);

if (process.env.TWC_QUIET !== '1') {
    const pad = (s, n) => String(s).padEnd(n);
    for (const [name, v] of toolEntries) {
        const line = `  ${pad(name, 14)} ${pad(v.installed || '-', 16)} → ${pad(v.latest || '-', 16)} ${v.state}`;
        console.log(line);
    }
    if (providerEntries.length > 0) {
        console.log('');
        for (const [name, v] of providerEntries) {
            const line = `  ${pad(name, 14)} ${pad(v.installed || '-', 16)} → ${pad(v.latest || '-', 16)} ${v.state}`;
            console.log(line);
        }
    }
    if (data.refresh_ok === false) {
        console.log('');
        console.log('  ⚠ marketplace refresh had errors — cache may understate available updates.');
    }
    if (updates.length > 0) {
        console.log('');
        console.log('  → ' + updates.length + ' update(s) available. Run `/tokenwar upgrade` to apply.');
    }
}
process.exit(updates.length > 0 ? 2 : 0);
NODESCRIPT
}
_render_cache "$CACHE_FILE" "$($quiet && echo 1 || echo 0)" "$STATUS_UPDATE"
