#!/usr/bin/env bats
# Tests for upgrade.sh — bumps the 4 tools, reads the throttled cache.

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../scripts/upgrade.sh"
    [ -x "$SCRIPT" ] || skip "upgrade.sh not executable"
    export HOME="$(mktemp -d)"
    mkdir -p "$HOME/.claude/tokenwar"
    MOCK_BIN="$(mktemp -d)"
    export ORIG_PATH="$PATH"
    export PATH="$MOCK_BIN:$PATH"
    export CLAUDE_LOG="$HOME/claude-calls.log"
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
{"tools":{"context-mode":{"state":"up-to-date"},"claude-mem":{"state":"up-to-date"},"caveman":{"state":"up-to-date"},"rtk":{"state":"up-to-date"}}}
EOF
    run bash "$SCRIPT" </dev/null
    [ "$status" -eq 0 ]
    [[ "$output" == *"nothing to upgrade"* ]]
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

@test "--all ignores cache and targets all four" {
    write_cache <<'EOF'
{"tools":{"context-mode":{"state":"up-to-date"},"claude-mem":{"state":"up-to-date"},"caveman":{"state":"up-to-date"},"rtk":{"state":"up-to-date"}}}
EOF
    run bash "$SCRIPT" --all </dev/null
    [[ "$output" == *"context-mode"* ]]
    [[ "$output" == *"claude-mem"* ]]
    [[ "$output" == *"caveman"* ]]
    [[ "$output" == *"rtk"* ]]
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

@test "unknown arg exits 2" {
    run bash "$SCRIPT" --bogus </dev/null
    [ "$status" -eq 2 ]
}
