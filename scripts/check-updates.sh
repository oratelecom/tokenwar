#!/usr/bin/env bash
# perfia check-updates — detect available upgrades for the 4-tool stack.
#
# Strategy: refresh marketplace manifests (throttled, 24h cache), then compare
# installed version vs marketplace `version` field for each plugin. For RTK,
# compare local `rtk --version` against `cargo search rtk` registry result.
#
# Output: one line per tool with status `up-to-date | update-available | ahead | unknown`.
# Exit codes: 0 = all up-to-date, 2 = at least one update available, 1 = error.
#
# Cache: ~/.claude/perfia/upgrade-check.json — refreshed when older than CACHE_TTL_SECONDS.
# Force refresh: pass --force.

set -euo pipefail

readonly CACHE_DIR="${HOME}/.claude/perfia"
readonly CACHE_FILE="${CACHE_DIR}/upgrade-check.json"
readonly CACHE_TTL_SECONDS=86400  # 24h

readonly SLUG_CTX="context-mode@context-mode"
readonly SLUG_MEM="claude-mem@thedotmack"
readonly SLUG_CAVE="caveman@caveman"

readonly MARKETPLACE_CTX="context-mode"
readonly MARKETPLACE_MEM="thedotmack"
readonly MARKETPLACE_CAVE="caveman"

readonly MARKETPLACE_ROOT="${HOME}/.claude/plugins/marketplaces"
readonly RTK_BIN="rtk"
readonly CLAUDE_BIN="claude"

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

# Refresh marketplaces (network call). Per-marketplace `git fetch && git pull
# --ff-only` so stale clones don't poison the cache with phantom "up-to-date"
# verdicts. Failures are surfaced on stderr (unless --quiet) but never abort —
# we still emit a cache below using whatever the clones currently hold, and
# the global `refresh_ok` flag tells consumers the cache may be stale.
#
# We intentionally do NOT call `claude plugin marketplace update` here: it
# races against the subsequent `claude plugin list --json` invocations (the
# CLI briefly returns an empty list while it rewrites its registry), and the
# per-clone `git pull --ff-only` above already refreshes every
# `marketplace.json` we read.
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
            $quiet || echo "perfia: marketplace clone missing: $dir" >&2
            rc=1
            continue
        fi
        if ! git -C "$dir" fetch --quiet 2>/dev/null; then
            $quiet || echo "perfia: git fetch failed for marketplace '$mp'" >&2
            rc=1
            continue
        fi
        if ! git -C "$dir" pull --ff-only --quiet 2>/dev/null; then
            $quiet || echo "perfia: git pull --ff-only failed for marketplace '$mp' (non-ff or conflict)" >&2
            rc=1
            continue
        fi
    done
    return $rc
}

# Read `version` from a marketplace.json's plugins[] entry matching `name`.
# Falls back to the marketplace clone's short git SHA (12 chars) when the
# manifest has no `version` field — caveman, e.g., versions by SHA only.
readonly MARKETPLACE_GIT_SHA_LEN=12
marketplace_version() {
    local marketplace="$1" plugin_name="$2"
    local marketplace_dir="${MARKETPLACE_ROOT}/${marketplace}"
    local manifest="${marketplace_dir}/.claude-plugin/marketplace.json"
    if [[ -f "$manifest" ]]; then
        local v
        v=$(MANIFEST_PATH="$manifest" PLUGIN_NAME="$plugin_name" node --input-type=module -e "
            import { readFileSync } from 'node:fs';
            const m = JSON.parse(readFileSync(process.env.MANIFEST_PATH, 'utf8'));
            const list = Array.isArray(m.plugins) ? m.plugins : [];
            const entry = list.find(p => p.name === process.env.PLUGIN_NAME);
            process.stdout.write(entry?.version || '');
        " 2>/dev/null || echo "")
        if [[ -n "$v" ]]; then echo "$v"; return; fi
    fi
    if [[ -d "${marketplace_dir}/.git" ]]; then
        git -C "$marketplace_dir" rev-parse --short="$MARKETPLACE_GIT_SHA_LEN" HEAD 2>/dev/null || echo ""
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

    ctx_latest=$(marketplace_version "$MARKETPLACE_CTX" "context-mode")
    mem_latest=$(marketplace_version "$MARKETPLACE_MEM" "claude-mem")
    cave_latest=$(marketplace_version "$MARKETPLACE_CAVE" "caveman")
    rtk_latest=$(rtk_latest_version)

    ctx_state=$(classify "$ctx_installed" "$ctx_latest")
    mem_state=$(classify "$mem_installed" "$mem_latest")
    cave_state=$(classify "$cave_installed" "$cave_latest")
    rtk_state=$(classify "$rtk_installed" "$rtk_latest")

    now=$(date +%s)
    PERFIA_CACHE_FILE="$CACHE_FILE" \
    NOW="$now" \
    REFRESH_OK="$($refresh_ok && echo 1 || echo 0)" \
    CTX_I="$ctx_installed" CTX_L="$ctx_latest" CTX_S="$ctx_state" \
    MEM_I="$mem_installed" MEM_L="$mem_latest" MEM_S="$mem_state" \
    CAVE_I="$cave_installed" CAVE_L="$cave_latest" CAVE_S="$cave_state" \
    RTK_I="$rtk_installed" RTK_L="$rtk_latest" RTK_S="$rtk_state" \
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
            }
        };
        writeFileSync(e.PERFIA_CACHE_FILE, JSON.stringify(data, null, 2));
    "
fi

# Render cache → stdout (unless --quiet, in which case only set exit code).
PERFIA_CACHE_FILE="$CACHE_FILE" QUIET="$($quiet && echo 1 || echo 0)" \
node --input-type=module -e "
    import { readFileSync } from 'node:fs';
    const data = JSON.parse(readFileSync(process.env.PERFIA_CACHE_FILE, 'utf8'));
    const entries = Object.entries(data.tools);
    const updates = entries.filter(([,v]) => v.state === '$STATUS_UPDATE');
    if (process.env.QUIET !== '1') {
        const pad = (s, n) => String(s).padEnd(n);
        for (const [name, v] of entries) {
            console.log(\`  \${pad(name,14)} \${pad(v.installed||'-',16)} → \${pad(v.latest||'-',16)} \${v.state}\`);
        }
        if (data.refresh_ok === false) {
            console.log('');
            console.log('  ⚠ marketplace refresh had errors — cache may understate available updates.');
        }
        if (updates.length > 0) {
            console.log('');
            console.log(\`  → \${updates.length} update(s) available. Run \\\`/perfia upgrade\\\` to apply.\`);
        }
    }
    process.exit(updates.length > 0 ? 2 : 0);
"
