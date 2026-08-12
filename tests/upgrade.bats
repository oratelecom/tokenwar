#!/usr/bin/env bats
# Tests for upgrade.sh — bumps managed tools, reads the throttled cache.

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../scripts/upgrade.sh"
    [ -x "$SCRIPT" ] || skip "upgrade.sh not executable"
    export HOME="$(mktemp -d)"
    mkdir -p "$HOME/.claude/tokenwar"
    MOCK_BIN="$(mktemp -d)"
    export ORIG_PATH="$PATH"
    export PATH="$MOCK_BIN:$PATH"
    export CLAUDE_LOG="$HOME/claude-calls.log"
    export NPM_LOG="$HOME/npm-calls.log"
}

teardown() {
    rm -rf "$HOME" "$MOCK_BIN"
    export PATH="$ORIG_PATH"
}

# Mock claude: records args; `plugin list --json` reports per-plugin scope.
mock_claude_scoped() {
    cat > "$MOCK_BIN/claude" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$CLAUDE_LOG"
if [[ "\$1 \$2 \$3" == "plugin list --json" ]]; then
cat <<'JSON'
[{"id":"context-mode@context-mode","scope":"user","enabled":true},
 {"id":"claude-mem@thedotmack","scope":"local","enabled":true},
 {"id":"caveman@caveman","scope":"user","enabled":true}]
JSON
fi
exit 0
EOF
    chmod +x "$MOCK_BIN/claude"
}

write_cache() {
    cat > "$HOME/.claude/tokenwar/upgrade-check.json"
}

@test "all up-to-date → nothing to upgrade, exit 0" {
    write_cache <<'EOF'
{"tools":{"context-mode":{"state":"up-to-date"},"claude-mem":{"state":"up-to-date"},"caveman":{"state":"up-to-date"},"rtk":{"state":"up-to-date"}},"providers":{"codex":{"state":"update-available"}}}
EOF
    run bash "$SCRIPT" </dev/null
    [ "$status" -eq 0 ]
    [[ "$output" == *"nothing to upgrade"* ]]
    [[ "$output" != *"codex"* ]]
}

@test "update available but no TTY → skip safely, exit 0, no /dev/tty error" {
    write_cache <<'EOF'
{"tools":{"context-mode":{"state":"update-available"},"claude-mem":{"state":"up-to-date"},"caveman":{"state":"up-to-date"},"rtk":{"state":"up-to-date"}}}
EOF
    run bash "$SCRIPT" </dev/null
    [ "$status" -eq 0 ]
    [[ "$output" == *"context-mode"* ]]
    [[ "$output" == *"No interactive terminal"* ]]
    [[ "$output" != *"No such device"* ]]
}

@test "lists only tools flagged update-available in the cache" {
    write_cache <<'EOF'
{"tools":{"context-mode":{"state":"up-to-date"},"claude-mem":{"state":"update-available"},"caveman":{"state":"update-available"},"rtk":{"state":"up-to-date"}}}
EOF
    run bash "$SCRIPT" </dev/null
    [[ "$output" == *"claude-mem"* ]]
    [[ "$output" == *"caveman"* ]]
    [[ "$output" != *"context-mode"* ]]
}

@test "--all ignores cache and targets every updater" {
    write_cache <<'EOF'
{"tools":{"context-mode":{"state":"up-to-date"},"claude-mem":{"state":"up-to-date"},"caveman":{"state":"up-to-date"},"rtk":{"state":"up-to-date"}}}
EOF
    run bash "$SCRIPT" --all </dev/null
    [[ "$output" == *"context-mode"* ]]
    [[ "$output" == *"claude-mem"* ]]
    [[ "$output" == *"caveman"* ]]
    [[ "$output" == *"rtk"* ]]
    [[ "$output" == *"pxpipe"* ]]
}

@test "plugin update passes each plugin's own --scope (local vs user)" {
    mock_claude_scoped
    # Flag only the two plugins (not rtk → upgrade_rtk, which touches cargo, never runs).
    write_cache <<'EOF'
{"tools":{"context-mode":{"state":"update-available"},"claude-mem":{"state":"update-available"},"caveman":{"state":"up-to-date"},"rtk":{"state":"up-to-date"}}}
EOF
    run bash "$SCRIPT" --yes </dev/null
    # claude-mem is local-scoped → must be updated with --scope local (the bug:
    # without it, `plugin update` defaults to user scope and fails).
    grep -q "plugin update claude-mem@thedotmack --scope local" "$CLAUDE_LOG"
    grep -q "plugin update context-mode@context-mode --scope user" "$CLAUDE_LOG"
}

@test "pxpipe update uses pinned npm package" {
    cat > "$MOCK_BIN/npm" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$NPM_LOG"
exit 0
EOF
    chmod +x "$MOCK_BIN/npm"
    write_cache <<'EOF'
{"tools":{"context-mode":{"state":"up-to-date"},"claude-mem":{"state":"up-to-date"},"caveman":{"state":"up-to-date"},"rtk":{"state":"up-to-date"},"pxpipe":{"state":"update-available"}}}
EOF
    run bash "$SCRIPT" --yes </dev/null
    [ "$status" -eq 0 ]
    grep -q "install -g pxpipe-proxy@0.10.0" "$NPM_LOG"
}

# Regression: the permanent-update loop. check-updates.sh reads "latest" from
# origin, but `claude plugin update` installs from the marketplace clone's LOCAL
# HEAD. If upgrade doesn't fast-forward the clone, a SHA-versioned plugin whose
# clone is behind origin reports update-available forever. Assert the clone is
# fast-forwarded to the upstream tip during upgrade.
@test "plugin update fast-forwards a stale marketplace clone before installing" {
    mock_claude_scoped
    # Bare upstream + a work tree with an initial commit.
    UP="$HOME/upstream.git"
    git init -q --bare -b main "$UP"
    WORK="$(mktemp -d)"
    git init -q -b main "$WORK"
    git -C "$WORK" config user.email t@t; git -C "$WORK" config user.name t
    echo v1 > "$WORK/f"; git -C "$WORK" add f; git -C "$WORK" commit -qm v1
    git -C "$WORK" remote add origin "$UP"; git -C "$WORK" push -q origin main
    # Clone into the marketplace location, pinned at v1 (the "stale" clone).
    CLONE="$HOME/.claude/plugins/marketplaces/caveman"
    mkdir -p "$(dirname "$CLONE")"
    git clone -q "$UP" "$CLONE"
    stale_head=$(git -C "$CLONE" rev-parse HEAD)
    # Advance upstream by one commit — clone is now behind origin.
    echo v2 > "$WORK/f"; git -C "$WORK" commit -qam v2; git -C "$WORK" push -q origin main
    tip=$(git -C "$WORK" rev-parse HEAD)

    write_cache <<'EOF'
{"tools":{"caveman":{"state":"update-available"},"context-mode":{"state":"up-to-date"},"claude-mem":{"state":"up-to-date"},"rtk":{"state":"up-to-date"}}}
EOF
    run bash "$SCRIPT" --yes </dev/null
    [ "$status" -eq 0 ]
    # Clone HEAD must have advanced from the stale commit to the upstream tip.
    new_head=$(git -C "$CLONE" rev-parse HEAD)
    [ "$new_head" = "$tip" ]
    [ "$new_head" != "$stale_head" ]
    rm -rf "$WORK"
}

@test "unknown arg exits 2" {
    run bash "$SCRIPT" --bogus </dev/null
    [ "$status" -eq 2 ]
}
