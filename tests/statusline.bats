#!/usr/bin/env bats
# Tests for perfia-statusline.sh — verifies badge color/active detection.
# Uses mocked `claude` + `rtk` to simulate each tool's state independently.

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../scripts/perfia-statusline.sh"
    [ -x "$SCRIPT" ] || skip "perfia-statusline.sh not executable"

    # Isolated mock PATH per test
    MOCK_BIN="$(mktemp -d)"
    export ORIG_PATH="$PATH"
    export PATH="$MOCK_BIN:$PATH"

    # Isolated fake HOME so settings.json is per-test
    export HOME="$(mktemp -d)"
    mkdir -p "$HOME/.claude"

    # ANSI color constants used by the script
    GREEN=$'\033[32m'
    RED=$'\033[31m'
    RESET=$'\033[0m'
}

teardown() {
    rm -rf "$MOCK_BIN" "$HOME"
    export PATH="$ORIG_PATH"
}

write_settings() {
    cat > "$HOME/.claude/settings.json"
}

mock_claude_with_plugins() {
    cat > "$MOCK_BIN/claude" <<EOF
#!/usr/bin/env bash
# Mock 'claude plugin list --json'
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
if [[ "$1" == "gain" ]]; then
    echo "RTK Token Savings"
    echo "Tokens saved:      44.7M (68.3%)"
fi
EOF
    chmod +x "$MOCK_BIN/rtk"
}

@test "all 4 tools active → all green" {
    write_settings <<'EOF'
{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"command":"/x/rtk-rewrite.sh"}]}]}}
EOF
    mock_claude_with_plugins '[
        {"id":"context-mode@context-mode","version":"1.0.107","enabled":true},
        {"id":"claude-mem@thedotmack","version":"12.1.4","enabled":true},
        {"id":"caveman@caveman","version":"84cc3c14fa1e","enabled":true}
    ]'
    mock_rtk_alive

    run bash "$SCRIPT" <<<'{}'
    [ "$status" -eq 0 ]
    [[ "$output" == *"${GREEN}[ctx 1.0.107]"* ]]
    [[ "$output" == *"${GREEN}[mem 12.1.4]"* ]]
    [[ "$output" == *"${GREEN}[rtk 44.7M]"* ]]
    [[ "$output" == *"${GREEN}[caveman 84cc3c1]"* ]]
}

@test "rtk hook missing → rtk red, others green" {
    write_settings <<'EOF'
{"hooks":{}}
EOF
    mock_claude_with_plugins '[
        {"id":"context-mode@context-mode","version":"1.0.107","enabled":true},
        {"id":"claude-mem@thedotmack","version":"12.1.4","enabled":true},
        {"id":"caveman@caveman","version":"84cc3c14fa1e","enabled":true}
    ]'
    mock_rtk_alive

    run bash "$SCRIPT" <<<'{}'
    [ "$status" -eq 0 ]
    [[ "$output" == *"${GREEN}[ctx 1.0.107]"* ]]
    [[ "$output" == *"${RED}[rtk -]"* ]]
    [[ "$output" == *"${GREEN}[caveman 84cc3c1]"* ]]
}

@test "context-mode disabled → ctx red" {
    write_settings <<'EOF'
{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"command":"/x/rtk-rewrite.sh"}]}]}}
EOF
    mock_claude_with_plugins '[
        {"id":"context-mode@context-mode","version":"1.0.107","enabled":false},
        {"id":"claude-mem@thedotmack","version":"12.1.4","enabled":true},
        {"id":"caveman@caveman","version":"84cc3c14fa1e","enabled":true}
    ]'
    mock_rtk_alive

    run bash "$SCRIPT" <<<'{}'
    [ "$status" -eq 0 ]
    [[ "$output" == *"${RED}[ctx 1.0.107]"* ]]
    [[ "$output" == *"${GREEN}[mem 12.1.4]"* ]]
}

@test "caveman not installed → caveman red with version=-" {
    write_settings <<'EOF'
{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"command":"/x/rtk-rewrite.sh"}]}]}}
EOF
    mock_claude_with_plugins '[
        {"id":"context-mode@context-mode","version":"1.0.107","enabled":true},
        {"id":"claude-mem@thedotmack","version":"12.1.4","enabled":true}
    ]'
    mock_rtk_alive

    run bash "$SCRIPT" <<<'{}'
    [ "$status" -eq 0 ]
    [[ "$output" == *"${RED}[caveman -]"* ]]
}

@test "all 4 down → all red" {
    write_settings <<'EOF'
{}
EOF
    mock_claude_with_plugins '[]'
    # No rtk binary

    run bash "$SCRIPT" <<<'{}'
    [ "$status" -eq 0 ]
    [[ "$output" == *"${RED}[ctx -]"* ]]
    [[ "$output" == *"${RED}[mem -]"* ]]
    [[ "$output" == *"${RED}[rtk -]"* ]]
    [[ "$output" == *"${RED}[caveman -]"* ]]
}

@test "version is SHA → truncated to 7 chars" {
    write_settings <<'EOF'
{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"command":"/x/rtk-rewrite.sh"}]}]}}
EOF
    mock_claude_with_plugins '[
        {"id":"caveman@caveman","version":"abcdef0123456789","enabled":true}
    ]'

    run bash "$SCRIPT" <<<'{}'
    [ "$status" -eq 0 ]
    [[ "$output" == *"[caveman abcdef0]"* ]]
}

@test "version is semver → kept as-is" {
    write_settings <<'EOF'
{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"command":"/x/rtk-rewrite.sh"}]}]}}
EOF
    mock_claude_with_plugins '[
        {"id":"context-mode@context-mode","version":"1.0.107","enabled":true}
    ]'

    run bash "$SCRIPT" <<<'{}'
    [ "$status" -eq 0 ]
    [[ "$output" == *"[ctx 1.0.107]"* ]]
}
