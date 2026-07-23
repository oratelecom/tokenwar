#!/usr/bin/env bats
# Tests for multi-provider support — Codex, Gemini, Kimi, Claude detection.

setup() {
    GAIN_SCRIPT="$BATS_TEST_DIRNAME/../scripts/gain.sh"
    STATUS_SCRIPT="$BATS_TEST_DIRNAME/../scripts/status.sh"

    export HOME="$(mktemp -d)"
    MOCK_BIN="$(mktemp -d)"
    export ORIG_PATH="$PATH"
    export PATH="$MOCK_BIN:$PATH"
    mkdir -p "$HOME/.claude/tokenwar"
}

teardown() {
    rm -rf "$HOME" "$MOCK_BIN"
    export PATH="$ORIG_PATH"
}

# ── Provider CLI detection in status.sh ─────────────────────────

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

mock_codex() {
    cat > "$MOCK_BIN/codex" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == "--version" ]] && echo "codex-cli 0.131.0"
exit 0
EOF
    chmod +x "$MOCK_BIN/codex"
}

mock_gemini() {
    cat > "$MOCK_BIN/gemini" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == "--version" ]] && echo "0.38.2"
exit 0
EOF
    chmod +x "$MOCK_BIN/gemini"
}

mock_kimi() {
    cat > "$MOCK_BIN/kimi" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == "--version" ]] && echo "kimi-code 0.9.1"
exit 0
EOF
    chmod +x "$MOCK_BIN/kimi"
}

@test "status.sh detects Codex CLI when installed" {
    mock_claude_with_plugins '[
      {"id":"context-mode@context-mode","version":"1.0.107","enabled":true},
      {"id":"claude-mem@thedotmack","version":"12.1.4","enabled":true},
      {"id":"caveman@caveman","version":"abc","enabled":true}
    ]'
    mock_rtk_alive
    mock_codex
    run bash "$STATUS_SCRIPT"
    [[ "$output" == *"Codex"*"0.131.0"*"OK"* ]]
}

@test "status.sh detects Codex when system-installed" {
    mock_claude_with_plugins '[
      {"id":"context-mode@context-mode","version":"1.0.107","enabled":true}
    ]'
    mock_rtk_alive
    # Codex is system-installed on dev machine — status.sh picks it up
    run bash "$STATUS_SCRIPT"
    # Codex should appear somewhere in the provider section
    [[ "$output" == *"Codex"* ]]
}

@test "status.sh detects Gemini CLI when installed" {
    mock_claude_with_plugins '[
      {"id":"context-mode@context-mode","version":"1.0.107","enabled":true},
      {"id":"claude-mem@thedotmack","version":"12.1.4","enabled":true},
      {"id":"caveman@caveman","version":"abc","enabled":true}
    ]'
    mock_rtk_alive
    mock_gemini
    run bash "$STATUS_SCRIPT"
    [[ "$output" == *"Gemini CLI"*"0.38.2"*"OK"* ]]
}

@test "status.sh detects Kimi Code CLI when installed" {
    mock_claude_with_plugins '[
      {"id":"context-mode@context-mode","version":"1.0.107","enabled":true},
      {"id":"claude-mem@thedotmack","version":"12.1.4","enabled":true},
      {"id":"caveman@caveman","version":"abc","enabled":true}
    ]'
    mock_rtk_alive
    mock_kimi
    run bash "$STATUS_SCRIPT"
    [[ "$output" == *"Kimi Code CLI"*"0.9.1"*"OK"* ]]
}

# ── Provider section in gain.sh ──────────────────────────────────

@test "gain.sh shows Codex in providers table" {
    mock_rtk_alive
    mock_codex
    # Codex SQLite won't exist in test HOME — shows N/A
    run bash "$GAIN_SCRIPT"
    [[ "$output" == *"Codex"*"N/A"* ]]
}

@test "gain.sh shows Gemini in providers table" {
    mock_rtk_alive
    mock_gemini
    run bash "$GAIN_SCRIPT"
    [[ "$output" == *"Gemini CLI"*"N/A"* ]]
}

@test "gain.sh shows Kimi Code CLI in providers table" {
    mock_rtk_alive
    mock_kimi
    run bash "$GAIN_SCRIPT"
    [[ "$output" == *"Kimi Code CLI"*"N/A"* ]]
}
