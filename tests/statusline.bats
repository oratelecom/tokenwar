#!/usr/bin/env bats
# Tests for tokenwar-statusline.sh — verifies badge color/active detection.
# Uses mocked `claude` + `rtk` to simulate each tool's state independently.

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../scripts/tokenwar-statusline.sh"
    [ -x "$SCRIPT" ] || skip "tokenwar-statusline.sh not executable"

    # Isolated mock PATH per test
    MOCK_BIN="$(mktemp -d)"
    export ORIG_PATH="$PATH"
    export PATH="$MOCK_BIN:$PATH"

    # Isolated fake HOME so settings.json is per-test
    export HOME="$(mktemp -d)"
    mkdir -p "$HOME/.claude"

    # Isolate the script's cache dir (${TMPDIR:-/tmp}) per test — otherwise the
    # 30s plugin/rtk caches leak across tests (and across real renders), so a
    # mock set in one test poisons the next. Hermetic TMPDIR fixes that.
    export TMPDIR="$HOME/tmp"
    mkdir -p "$TMPDIR"

    # Default upgrade-check cache: everything up-to-date. Keeps the bar free of
    # ⬆ markers for the legacy tests AND — being freshly written — stops the
    # statusline from spawning a real (networked) background refresh per test.
    default_uptodate_cache

    # ANSI color constants used by the script
    GREEN=$'\033[32m'
    RED=$'\033[31m'
    YELLOW=$'\033[33m'
    RESET=$'\033[0m'
}

teardown() {
    rm -rf "$MOCK_BIN" "$HOME"
    export PATH="$ORIG_PATH"
}

write_update_cache() {
    mkdir -p "$HOME/.claude/tokenwar"
    cat > "$HOME/.claude/tokenwar/upgrade-check.json"
}

default_uptodate_cache() {
    write_update_cache <<'EOF'
{"refresh_ok":true,"tools":{
  "context-mode":{"state":"up-to-date"},
  "claude-mem":{"state":"up-to-date"},
  "caveman":{"state":"up-to-date"},
  "rtk":{"state":"up-to-date"}
}}
EOF
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

@test "update-available in cache → ⬆ on that tool only" {
    write_settings <<'EOF'
{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"command":"/x/rtk-rewrite.sh"}]}]}}
EOF
    mock_claude_with_plugins '[
        {"id":"context-mode@context-mode","version":"1.0.107","enabled":true},
        {"id":"claude-mem@thedotmack","version":"12.1.4","enabled":true},
        {"id":"caveman@caveman","version":"84cc3c14fa1e","enabled":true}
    ]'
    mock_rtk_alive
    write_update_cache <<'EOF'
{"refresh_ok":true,"tools":{
  "context-mode":{"state":"update-available"},
  "claude-mem":{"state":"up-to-date"},
  "caveman":{"state":"up-to-date"},
  "rtk":{"state":"up-to-date"}
}}
EOF
    run bash "$SCRIPT" <<<'{}'
    [ "$status" -eq 0 ]
    # ctx carries the marker, exactly one ⬆ across the whole bar
    [[ "$output" == *"[ctx 1.0.107 "*"⬆"*"]"* ]]
    # one ⬆ on the ctx badge + one in the CTA suffix
    [ "$(grep -o '⬆' <<<"$output" | wc -l)" -eq 2 ]
    # singular CTA pointing at the upgrade command
    [[ "$output" == *"1 update · /tokenwar upgrade"* ]]
    [[ "$output" != *"updates"* ]]
}

@test "multiple updates → plural CTA with count" {
    write_settings <<'EOF'
{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"command":"/x/rtk-rewrite.sh"}]}]}}
EOF
    mock_claude_with_plugins '[
        {"id":"context-mode@context-mode","version":"1.0.107","enabled":true},
        {"id":"claude-mem@thedotmack","version":"12.1.4","enabled":true},
        {"id":"caveman@caveman","version":"84cc3c14fa1e","enabled":true}
    ]'
    mock_rtk_alive
    write_update_cache <<'EOF'
{"refresh_ok":true,"tools":{
  "context-mode":{"state":"update-available"},
  "claude-mem":{"state":"update-available"},
  "caveman":{"state":"up-to-date"},
  "rtk":{"state":"up-to-date"}
}}
EOF
    run bash "$SCRIPT" <<<'{}'
    [ "$status" -eq 0 ]
    [[ "$output" == *"2 updates · /tokenwar upgrade"* ]]
}

@test "all up-to-date in cache → no ⬆ marker, no CTA" {
    write_settings <<'EOF'
{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"command":"/x/rtk-rewrite.sh"}]}]}}
EOF
    mock_claude_with_plugins '[
        {"id":"context-mode@context-mode","version":"1.0.107","enabled":true}
    ]'

    run bash "$SCRIPT" <<<'{}'
    [ "$status" -eq 0 ]
    [[ "$output" != *"⬆"* ]]
    [[ "$output" != *"/tokenwar upgrade"* ]]
}
