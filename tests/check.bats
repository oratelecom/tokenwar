#!/usr/bin/env bats
# Tests for check.sh — conflict detection rules R1-R4.

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../scripts/check.sh"
    [ -x "$SCRIPT" ] || skip "check.sh not executable"

    export HOME="$(mktemp -d)"
    mkdir -p "$HOME/.claude/hooks"
}

teardown() {
    rm -rf "$HOME"
}

@test "R1 PASS — single Bash PreToolUse hook" {
    cat > "$HOME/.claude/settings.json" <<'EOF'
{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"command":"/x/rtk-rewrite.sh"}]}]}}
EOF
    run bash "$SCRIPT"
    [[ "$output" == *"R1 bash double-hook"*PASS* ]]
}

@test "R1 WARN — no Bash hook" {
    echo '{}' > "$HOME/.claude/settings.json"
    run bash "$SCRIPT"
    [[ "$output" == *"R1 bash double-hook"*WARN* ]]
}

@test "R1 FAIL — multiple Bash hooks" {
    cat > "$HOME/.claude/settings.json" <<'EOF'
{"hooks":{"PreToolUse":[
  {"matcher":"Bash","hooks":[{"command":"/x/rtk-rewrite.sh"}]},
  {"matcher":"Bash","hooks":[{"command":"/x/another.sh"}]}
]}}
EOF
    run bash "$SCRIPT"
    [[ "$output" == *"R1 bash double-hook"*FAIL* ]]
}

@test "R2 PASS — claude-mem dir exists, disjoint sinks" {
    echo '{}' > "$HOME/.claude/settings.json"
    # Simulate installed_plugins with claude-mem
    mkdir -p "$HOME/.claude/plugins"
    cat > "$HOME/.claude/plugins/installed_plugins.json" <<'EOF'
{"plugins":{"claude-mem@thedotmack":[{"version":"12.1.4"}]}}
EOF
    mkdir -p "$HOME/.claude-mem"
    run bash "$SCRIPT"
    [[ "$output" == *"R2 memory source overlap"*PASS* ]]
}

@test "R3 always PASS — disjoint buffers" {
    echo '{}' > "$HOME/.claude/settings.json"
    run bash "$SCRIPT"
    [[ "$output" == *"R3 output compression"*PASS* ]]
}

@test "Verdict COMPLEMENTARY when all PASS" {
    cat > "$HOME/.claude/settings.json" <<'EOF'
{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"command":"/x/rtk-rewrite.sh"}]}]}}
EOF
    mkdir -p "$HOME/.claude/plugins" "$HOME/.claude-mem"
    cat > "$HOME/.claude/plugins/installed_plugins.json" <<'EOF'
{"plugins":{
  "context-mode@context-mode":[{"version":"1.0.107"}],
  "claude-mem@thedotmack":[{"version":"12.1.4"}],
  "caveman@caveman":[{"version":"abc"}]
}}
EOF
    # Provide rtk command so R4 doesn't fail
    export PATH="$HOME/bin:$PATH"
    mkdir -p "$HOME/bin"
    echo '#!/usr/bin/env bash' > "$HOME/bin/rtk"
    chmod +x "$HOME/bin/rtk"

    run bash "$SCRIPT"
    [[ "$output" == *"COMPLEMENTARY"* ]]
}
