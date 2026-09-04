#!/usr/bin/env bats
# Tests for check.sh — conflict detection rules R1-R5.

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
  "caveman@caveman":[{"version":"abc"}],
  "ponytail@ponytail":[{"version":"4.2.0"}]
}}
EOF
    # Provide command stubs so R4 doesn't fail. Every non-plugin tool R4 checks
    # needs one — a runner has none of them installed, so a missing stub turns
    # the verdict into DEGRADED and this test stops testing the verdict.
    export PATH="$HOME/bin:$PATH"
    mkdir -p "$HOME/bin"
    for tool in rtk pxpipe graphify; do
        echo '#!/usr/bin/env bash' > "$HOME/bin/$tool"
        chmod +x "$HOME/bin/$tool"
    done

    run bash "$SCRIPT"
    [[ "$output" == *"COMPLEMENTARY"* ]]
}

@test "R4 WARN — graphify CLI absent" {
    cat > "$HOME/.claude/settings.json" <<'EOF'
{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"command":"/x/rtk-rewrite.sh"}]}]}}
EOF
    mkdir -p "$HOME/.claude/plugins" "$HOME/.claude-mem" "$HOME/bin"
    cat > "$HOME/.claude/plugins/installed_plugins.json" <<'EOF'
{"plugins":{
  "context-mode@context-mode":[{"version":"1.0.107"}],
  "claude-mem@thedotmack":[{"version":"12.1.4"}],
  "caveman@caveman":[{"version":"abc"}],
  "ponytail@ponytail":[{"version":"4.2.0"}]
}}
EOF
    for tool in rtk pxpipe; do
        echo '#!/usr/bin/env bash' > "$HOME/bin/$tool"
        chmod +x "$HOME/bin/$tool"
    done
    # graphify deliberately absent. Narrow PATH so the developer's own
    # ~/.local/bin/graphify cannot satisfy the check and hide the regression.
    ln -sf "$(command -v node)" "$HOME/bin/node"
    PATH="$HOME/bin:/usr/bin:/bin"

    run bash "$SCRIPT"
    [[ "$output" == *"R4 version drift"*WARN* ]]
    [[ "$output" == *"not installed: graphify"* ]]
    [ "$status" -eq 1 ]
}
