#!/usr/bin/env bats
# Tests for status.sh — reports state of the 7 tools using `claude plugin list --json`.

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../scripts/status.sh"
    [ -x "$SCRIPT" ] || skip "status.sh not executable"

    MOCK_BIN="$(mktemp -d)"
    export ORIG_PATH="$PATH"
    export PATH="$MOCK_BIN:$PATH"

    # Isolated fake HOME: graphify's state depends on a skill file under
    # ~/.claude, and status.sh tails an upgrade-check pass. Seeding a FRESH
    # all-up-to-date cache keeps both hermetic — no host state leaks in, and the
    # 24h throttle stops CI from making a real network refresh mid-test.
    export HOME="$(mktemp -d)"
    mkdir -p "$HOME/.claude/tokenwar"
    write_uptodate_cache
}

teardown() {
    rm -rf "$MOCK_BIN" "$HOME"
    export PATH="$ORIG_PATH"
}

write_uptodate_cache() {
    cat > "$HOME/.claude/tokenwar/upgrade-check.json" <<'EOF'
{"refresh_ok":true,"tools":{"context-mode":{"state":"up-to-date"},"claude-mem":{"state":"up-to-date"},"caveman":{"state":"up-to-date"},"rtk":{"state":"up-to-date"},"pxpipe":{"state":"up-to-date"},"graphify":{"state":"up-to-date"}}}
EOF
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

# graphify is healthy only when BOTH halves are present: the CLI on PATH and the
# skill registered with the assistant. mock_graphify_cli covers the first half so
# the "CLI without skill" case stays testable on its own.
mock_graphify_cli() {
    cat > "$MOCK_BIN/graphify" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == "--version" ]] && echo "graphify 0.9.53"
exit 0
EOF
    chmod +x "$MOCK_BIN/graphify"
}

mock_graphify_alive() {
    mock_graphify_cli
    mkdir -p "$HOME/.claude/skills/graphify"
    echo "# graphify skill" > "$HOME/.claude/skills/graphify/SKILL.md"
}

@test "exit 0 when all 7 tools healthy" {
    mock_claude_with_plugins '[
      {"id":"context-mode@context-mode","version":"1.0.107","enabled":true},
      {"id":"claude-mem@thedotmack","version":"12.1.4","enabled":true},
      {"id":"caveman@caveman","version":"abc","enabled":true},
      {"id":"ponytail@ponytail","version":"4.5.0","enabled":true}
    ]'
    mock_rtk_alive
    mock_pxpipe_alive
    mock_graphify_alive
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"context-mode"*"OK"* ]]
    [[ "$output" == *"claude-mem"*"OK"* ]]
    [[ "$output" == *"caveman"*"OK"* ]]
    [[ "$output" == *"ponytail"*"OK"* ]]
    [[ "$output" == *"rtk"*"OK"* ]]
    [[ "$output" == *"pxpipe"*"0.10.0"*"OK"* ]]
    [[ "$output" == *"graphify"*"0.9.53"*"OK"* ]]
}

@test "exit 1 when only ponytail is missing (the other 6 healthy)" {
    mock_claude_with_plugins '[
      {"id":"context-mode@context-mode","version":"1.0.107","enabled":true},
      {"id":"claude-mem@thedotmack","version":"12.1.4","enabled":true},
      {"id":"caveman@caveman","version":"abc","enabled":true}
    ]'
    mock_rtk_alive
    mock_pxpipe_alive
    mock_graphify_alive
    run bash "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"ponytail"*"not-installed"* ]]
}

@test "exit 0 when 7 tools healthy and optional providers absent" {
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
    mock_graphify_alive
    ln -s "$(command -v node)" "$MOCK_BIN/node"   # resolve node BEFORE we shrink PATH
    PATH="$MOCK_BIN:/usr/bin:/bin"                  # excludes user CLI dirs → providers not found
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"context-mode"*"OK"* ]]
    [[ "$output" == *"rtk"*"OK"* ]]
    [[ "$output" == *"pxpipe"*"OK"* ]]
    [[ "$output" == *"graphify"*"OK"* ]]
}

@test "exit 1 when a plugin is missing" {
    mock_claude_with_plugins '[
      {"id":"context-mode@context-mode","version":"1.0.107","enabled":true}
    ]'
    mock_rtk_alive
    mock_pxpipe_alive
    mock_graphify_alive
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
    mock_graphify_alive
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
    mock_graphify_alive

    # Provide claude-mem binary for ping
    cat > "$MOCK_BIN/claude-mem" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "$MOCK_BIN/claude-mem"

    run bash "$SCRIPT" --test
    [[ "$output" == *"ping="* ]]
    [[ "$output" == *"pxpipe"*"ping=ok"* ]]
    [[ "$output" == *"graphify"*"ping=ok"* ]]
}

@test "exit 1 when pxpipe is missing" {
    mock_claude_with_plugins '[
      {"id":"context-mode@context-mode","version":"1.0.107","enabled":true},
      {"id":"claude-mem@thedotmack","version":"12.1.4","enabled":true},
      {"id":"caveman@caveman","version":"abc","enabled":true},
      {"id":"ponytail@ponytail","version":"4.5.0","enabled":true}
    ]'
    mock_rtk_alive
    mock_graphify_alive
    ln -s "$(command -v node)" "$MOCK_BIN/node"
    PATH="$MOCK_BIN:/usr/bin:/bin"
    run bash "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"pxpipe"*"not-installed"* ]]
}

@test "provider-only update does not advertise managed upgrade command" {
    mock_claude_with_plugins '[
      {"id":"context-mode@context-mode","version":"1.0.107","enabled":true},
      {"id":"claude-mem@thedotmack","version":"12.1.4","enabled":true},
      {"id":"caveman@caveman","version":"abc","enabled":true},
      {"id":"ponytail@ponytail","version":"4.5.0","enabled":true}
    ]'
    mock_rtk_alive
    mock_pxpipe_alive
    mock_graphify_alive
    cat > "$HOME/.claude/tokenwar/upgrade-check.json" <<'EOF'
{"refresh_ok":true,"tools":{"context-mode":{"state":"up-to-date"},"claude-mem":{"state":"up-to-date"},"caveman":{"state":"up-to-date"},"rtk":{"state":"up-to-date"},"pxpipe":{"state":"up-to-date"},"graphify":{"state":"up-to-date"}},"providers":{"codex":{"installed":"0.146.0","latest":"0.147.0","state":"update-available"}}}
EOF

    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" != *"updates available (0)"* ]]
    [[ "$output" != *"/tokenwar upgrade"* ]]
}

@test "graphify absent → not-installed and exit 1" {
    mock_claude_with_plugins '[
      {"id":"context-mode@context-mode","version":"1.0.107","enabled":true},
      {"id":"claude-mem@thedotmack","version":"12.1.4","enabled":true},
      {"id":"caveman@caveman","version":"abc","enabled":true},
      {"id":"ponytail@ponytail","version":"4.5.0","enabled":true}
    ]'
    mock_rtk_alive
    mock_pxpipe_alive
    ln -s "$(command -v node)" "$MOCK_BIN/node"
    PATH="$MOCK_BIN:/usr/bin:/bin"     # excludes ~/.local/bin → no host graphify
    run bash "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"graphify"*"not-installed"* ]]
}

@test "graphify CLI without a registered skill reports installed-disabled" {
    # The CLI alone builds graphs no assistant knows to query, so a missing
    # SKILL.md is a real degraded state — not a healthy install.
    mock_claude_with_plugins '[
      {"id":"context-mode@context-mode","version":"1.0.107","enabled":true},
      {"id":"claude-mem@thedotmack","version":"12.1.4","enabled":true},
      {"id":"caveman@caveman","version":"abc","enabled":true},
      {"id":"ponytail@ponytail","version":"4.5.0","enabled":true}
    ]'
    mock_rtk_alive
    mock_pxpipe_alive
    mock_graphify_cli                   # CLI only — no skill file written
    run bash "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"graphify"*"installed-disabled"* ]]
}

@test "--json exposes graphify alongside the other six tools" {
    mock_claude_with_plugins '[
      {"id":"context-mode@context-mode","version":"1.0.107","enabled":true},
      {"id":"claude-mem@thedotmack","version":"12.1.4","enabled":true},
      {"id":"caveman@caveman","version":"abc","enabled":true},
      {"id":"ponytail@ponytail","version":"4.5.0","enabled":true}
    ]'
    mock_rtk_alive
    mock_pxpipe_alive
    mock_graphify_alive
    run bash "$SCRIPT" --json
    [ "$status" -eq 0 ]
    echo "$output" | node -e '
        let s = "";
        process.stdin.on("data", d => s += d).on("end", () => {
            const j = JSON.parse(s);
            if (j.tools["graphify"].state !== "OK") process.exit(1);
            if (j.tools["graphify"].version !== "0.9.53") process.exit(1);
            if (j.ok !== true) process.exit(1);
        });
    '
}
