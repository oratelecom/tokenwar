#!/usr/bin/env bats
# Tests for toggle.sh — `tokenwar enable|disable <tool>`.

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../scripts/toggle.sh"
    [ -x "$SCRIPT" ] || skip "toggle.sh not executable"

    MOCK_BIN="$(mktemp -d)"
    export ORIG_PATH="$PATH"
    export PATH="$MOCK_BIN:$PATH"
    # Record what `claude plugin ...` was called with.
    export CLAUDE_CALL_LOG="$MOCK_BIN/claude-calls.log"
}

teardown() {
    rm -rf "$MOCK_BIN"
    export PATH="$ORIG_PATH"
}

# Mock a `claude` CLI whose `plugin enable|disable` succeeds and logs its args.
mock_claude_ok() {
    cat > "$MOCK_BIN/claude" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "$CLAUDE_CALL_LOG"
exit 0
EOF
    chmod +x "$MOCK_BIN/claude"
}

# Mock a `claude` whose `plugin` verb fails.
mock_claude_fail() {
    cat > "$MOCK_BIN/claude" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
    chmod +x "$MOCK_BIN/claude"
}

@test "disable context-mode calls claude plugin disable with the right slug" {
    mock_claude_ok
    run bash "$SCRIPT" disable context-mode
    [ "$status" -eq 0 ]
    [[ "$output" == *"disabled context-mode"* ]]
    grep -qF "plugin disable context-mode@context-mode" "$CLAUDE_CALL_LOG"
}

@test "enable claude-mem calls claude plugin enable with the right slug" {
    mock_claude_ok
    run bash "$SCRIPT" enable claude-mem
    [ "$status" -eq 0 ]
    [[ "$output" == *"enabled claude-mem"* ]]
    grep -qF "plugin enable claude-mem@thedotmack" "$CLAUDE_CALL_LOG"
}

@test "every plugin tool maps to a slug" {
    mock_claude_ok
    for tool in context-mode claude-mem caveman ponytail; do
        run bash "$SCRIPT" disable "$tool"
        [ "$status" -eq 0 ]
    done
}

@test "rtk is refused as a non-plugin with a pointer (exit 3)" {
    mock_claude_ok
    run bash "$SCRIPT" disable rtk
    [ "$status" -eq 3 ]
    [[ "$output" == *"standalone binary"* ]]
    [ ! -f "$CLAUDE_CALL_LOG" ]   # never touched claude
}

@test "pxpipe is refused as a non-plugin with a pointer (exit 3)" {
    mock_claude_ok
    run bash "$SCRIPT" disable pxpipe
    [ "$status" -eq 3 ]
    [[ "$output" == *"proxy binary"* ]]
}

@test "unknown tool exits 2 with usage" {
    mock_claude_ok
    run bash "$SCRIPT" disable bogus
    [ "$status" -eq 2 ]
    [[ "$output" == *"unknown tool"* ]]
}

@test "unknown action exits 2" {
    run bash "$SCRIPT" frobnicate context-mode
    [ "$status" -eq 2 ]
    [[ "$output" == *"unknown action"* ]]
}

@test "missing tool name exits 2" {
    run bash "$SCRIPT" disable
    [ "$status" -eq 2 ]
}

@test "propagates a claude plugin failure (exit 1)" {
    mock_claude_fail
    run bash "$SCRIPT" disable context-mode
    [ "$status" -eq 1 ]
    [[ "$output" == *"failed"* ]]
}

@test "dispatcher routes disable to toggle.sh" {
    mock_claude_ok
    run bash "$BATS_TEST_DIRNAME/../scripts/tokenwar.sh" disable context-mode
    [ "$status" -eq 0 ]
    [[ "$output" == *"disabled context-mode"* ]]
}
