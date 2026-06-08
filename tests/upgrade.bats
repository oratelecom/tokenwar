#!/usr/bin/env bats
# Tests for upgrade.sh — bumps the 4 tools, reads the throttled cache.

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../scripts/upgrade.sh"
    [ -x "$SCRIPT" ] || skip "upgrade.sh not executable"
    export HOME="$(mktemp -d)"
    mkdir -p "$HOME/.claude/tokenwar"
}

teardown() {
    rm -rf "$HOME"
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

@test "unknown arg exits 2" {
    run bash "$SCRIPT" --bogus </dev/null
    [ "$status" -eq 2 ]
}
