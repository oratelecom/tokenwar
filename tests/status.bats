#!/usr/bin/env bats
# Tests for status.sh — reports state of the 6 tools using `claude plugin list --json`.

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../scripts/status.sh"
    [ -x "$SCRIPT" ] || skip "status.sh not executable"

    MOCK_BIN="$(mktemp -d)"
    export ORIG_PATH="$PATH"
    export PATH="$MOCK_BIN:$PATH"
}

teardown() {
    rm -rf "$MOCK_BIN"
    export PATH="$ORIG_PATH"
}

mock_claude_with_plugins() {
    cat > "$MOCK_BIN/claude" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "plugin" && "\$2" == "list" && "\$3" == "--json" ]]; then
    cat <<JSON
$1
JSON
fi
EOF
    chmod +x "$MOCK_BIN/claude"
}

mock_rtk_alive() {
    cat > "$MOCK_BIN/rtk" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == "gain" ]] && echo "Tokens saved: 1M"
[[ "$1" == "--version" ]] && echo "rtk 0.30.1"
exit 0
EOF
    chmod +x "$MOCK_BIN/rtk"
}

mock_pxpipe_alive() {
    cat > "$MOCK_BIN/pxpipe" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == "--version" ]] && echo "0.10.0"
exit 0
EOF
    chmod +x "$MOCK_BIN/pxpipe"
}

@test "exit 0 when all 6 tools healthy" {
    mock_claude_with_plugins '[
      {"id":"context-mode@context-mode","version":"1.0.107","enabled":true},
      {"id":"claude-mem@thedotmack","version":"12.1.4","enabled":true},
      {"id":"caveman@caveman","version":"abc","enabled":true},
      {"id":"ponytail@ponytail","version":"4.5.0","enabled":true}
    ]'
    mock_rtk_alive
    mock_pxpipe_alive
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"context-mode"*"OK"* ]]
    [[ "$output" == *"claude-mem"*"OK"* ]]
    [[ "$output" == *"caveman"*"OK"* ]]
    [[ "$output" == *"ponytail"*"OK"* ]]
    [[ "$output" == *"rtk"*"OK"* ]]
    [[ "$output" == *"pxpipe"*"0.10.0"*"OK"* ]]
}

@test "exit 1 when only ponytail is missing (the other 5 healthy)" {
    mock_claude_with_plugins '[
      {"id":"context-mode@context-mode","version":"1.0.107","enabled":true},
      {"id":"claude-mem@thedotmack","version":"12.1.4","enabled":true},
      {"id":"caveman@caveman","version":"abc","enabled":true}
    ]'
    mock_rtk_alive
    mock_pxpipe_alive
    run bash "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"ponytail"*"not-installed"* ]]
}

@test "exit 0 when 6 tools healthy and optional providers absent" {
    # Regression for the CI break: status.sh used to gate its exit code on
    # provider health, so absent provider CLIs (every Claude-only host and the
    # CI runner) forced exit 1. Reproduce that hermetically by stripping the real
    # CLIs from PATH (keeping node, which the script needs, + the mock claude).
    mock_claude_with_plugins '[
      {"id":"context-mode@context-mode","version":"1.0.107","enabled":true},
      {"id":"claude-mem@thedotmack","version":"12.1.4","enabled":true},
      {"id":"caveman@caveman","version":"abc","enabled":true},
      {"id":"ponytail@ponytail","version":"4.5.0","enabled":true}
    ]'
    mock_rtk_alive
    mock_pxpipe_alive
    ln -s "$(command -v node)" "$MOCK_BIN/node"   # resolve node BEFORE we shrink PATH
    PATH="$MOCK_BIN:/usr/bin:/bin"                  # excludes user CLI dirs → providers not found
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"context-mode"*"OK"* ]]
    [[ "$output" == *"rtk"*"OK"* ]]
    [[ "$output" == *"pxpipe"*"OK"* ]]
}

@test "exit 1 when a plugin is missing" {
    mock_claude_with_plugins '[
      {"id":"context-mode@context-mode","version":"1.0.107","enabled":true}
    ]'
    mock_rtk_alive
    mock_pxpipe_alive
    run bash "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"not-installed"* ]]
}

@test "exit 1 when a plugin is installed-disabled" {
    mock_claude_with_plugins '[
      {"id":"context-mode@context-mode","version":"1.0.107","enabled":false},
      {"id":"claude-mem@thedotmack","version":"12.1.4","enabled":true},
      {"id":"caveman@caveman","version":"abc","enabled":true}
    ]'
    mock_rtk_alive
    mock_pxpipe_alive
    run bash "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"installed-disabled"* ]]
}

@test "--test mode adds ping column" {
    mock_claude_with_plugins '[
      {"id":"context-mode@context-mode","version":"1.0.107","enabled":true},
      {"id":"claude-mem@thedotmack","version":"12.1.4","enabled":true},
      {"id":"caveman@caveman","version":"abc","enabled":true},
      {"id":"ponytail@ponytail","version":"4.5.0","enabled":true}
    ]'
    mock_rtk_alive
    mock_pxpipe_alive

    # Provide claude-mem binary for ping
    cat > "$MOCK_BIN/claude-mem" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "$MOCK_BIN/claude-mem"

    run bash "$SCRIPT" --test
    [[ "$output" == *"ping="* ]]
    [[ "$output" == *"pxpipe"*"ping=ok"* ]]
}

@test "exit 1 when pxpipe is missing" {
    mock_claude_with_plugins '[
      {"id":"context-mode@context-mode","version":"1.0.107","enabled":true},
      {"id":"claude-mem@thedotmack","version":"12.1.4","enabled":true},
      {"id":"caveman@caveman","version":"abc","enabled":true},
      {"id":"ponytail@ponytail","version":"4.5.0","enabled":true}
    ]'
    mock_rtk_alive
    ln -s "$(command -v node)" "$MOCK_BIN/node"
    PATH="$MOCK_BIN:/usr/bin:/bin"
    run bash "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"pxpipe"*"not-installed"* ]]
}
