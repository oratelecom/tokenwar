#!/usr/bin/env bats
# Tests for copilot.sh — pointing the stack at GitHub Copilot CLI's own
# extension points (hook / skills / MCP).
#
# Copilot is wired from THREE different mechanisms, so the tests assert the
# mechanism actually used, not just "something happened": rtk goes through its
# own installer, skills go through `copilot skill add` (Copilot owns the layout
# of ~/.copilot/skills), and claude-mem is re-registered from its OWN .mcp.json
# so the wiring survives a claude-mem upgrade.

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../scripts/copilot.sh"
    [ -x "$SCRIPT" ] || skip "copilot.sh not executable"

    MOCK_BIN="$(mktemp -d)"
    export ORIG_PATH="$PATH"
    export PATH="$MOCK_BIN:$PATH"

    export HOME="$(mktemp -d)"
    export CLAUDE_CONFIG_DIR="$HOME/.claude"
    export COPILOT_HOME="$HOME/.copilot"
    mkdir -p "$COPILOT_HOME"

    export CALL_LOG="$HOME/calls.log"
    export MCP_ARGS_DUMP="$HOME/mcp-args.txt"
}

teardown() {
    export PATH="$ORIG_PATH"
    rm -rf "$MOCK_BIN" "$HOME"
}

# `copilot skill add <file>` materialises the skill under ~/.copilot/skills/<name>.
# The mock reproduces that so state detection can be asserted after wiring.
mock_copilot() {
    cat > "$MOCK_BIN/copilot" <<EOF
#!/usr/bin/env bash
echo "copilot \$*" >> "$CALL_LOG"
if [[ "\$1" == "skill" && "\$2" == "add" ]]; then
    name=\$(sed -n 's/^name:[[:space:]]*//p' "\$3" | head -1)
    mkdir -p "$COPILOT_HOME/skills/\$name"
    cp "\$3" "$COPILOT_HOME/skills/\$name/SKILL.md"
fi
if [[ "\$1" == "mcp" && "\$2" == "add" ]]; then
    # Record every argv element on its own line so the test can assert the
    # exact command+args that were forwarded, whitespace included.
    printf '%s\\n' "\$@" > "$MCP_ARGS_DUMP"
    mkdir -p "$COPILOT_HOME"
    printf '{"mcpServers":{"%s":{}}}' "\$3" > "$COPILOT_HOME/mcp-config.json"
fi
exit 0
EOF
    chmod +x "$MOCK_BIN/copilot"
}

mock_rtk() {
    cat > "$MOCK_BIN/rtk" <<EOF
#!/usr/bin/env bash
echo "rtk \$*" >> "$CALL_LOG"
if [[ "\$1" == "init" ]]; then
    mkdir -p "$COPILOT_HOME/hooks"
    echo '{"version":1}' > "$COPILOT_HOME/hooks/rtk-rewrite.json"
fi
exit 0
EOF
    chmod +x "$MOCK_BIN/rtk"
}

mock_graphify() {
    cat > "$MOCK_BIN/graphify" <<EOF
#!/usr/bin/env bash
echo "graphify \$*" >> "$CALL_LOG"
if [[ "\$1" == "copilot" && "\$2" == "install" ]]; then
    mkdir -p "$COPILOT_HOME/skills/graphify"
    echo "# graphify" > "$COPILOT_HOME/skills/graphify/SKILL.md"
fi
exit 0
EOF
    chmod +x "$MOCK_BIN/graphify"
}

# A plugin cache entry, versioned like the real one (semver or git SHA).
seed_plugin_skill() {
    local rel="$1" version="$2" skill="$3"
    local dir="$CLAUDE_CONFIG_DIR/plugins/cache/$rel/$version/skills/$skill"
    mkdir -p "$dir"
    printf -- '---\nname: %s\ndescription: test\n---\nbody\n' "$skill" > "$dir/SKILL.md"
}

seed_claude_mem_mcp() {
    local dir="$CLAUDE_CONFIG_DIR/plugins/cache/thedotmack/claude-mem/13.6.1"
    mkdir -p "$dir"
    cat > "$dir/.mcp.json" <<'EOF'
{"mcpServers":{"mcp-search":{"type":"stdio","command":"node","args":["-e","const locator = 1; // long inline script"]}}}
EOF
}

seed_all_sources() {
    mock_rtk
    mock_graphify
    seed_plugin_skill "caveman/caveman" "766dce6b1394" "caveman"
    seed_plugin_skill "ponytail/ponytail" "4.9.0" "ponytail"
    seed_claude_mem_mcp
}

# ── check ─────────────────────────────────────────────────────────

@test "no Copilot CLI → refuses with an install hint, exit 1" {
    seed_all_sources
    ln -sf "$(command -v node)" "$MOCK_BIN/node"
    PATH="$MOCK_BIN:/usr/bin:/bin"     # excludes ~/.nvm etc, so no real copilot
    run bash "$SCRIPT" check
    [ "$status" -eq 1 ]
    [[ "$output" == *"Copilot CLI not installed"* ]]
    [[ "$output" == *"@github/copilot"* ]]
}

@test "check reports every installed-but-unwired tool and exits 1" {
    mock_copilot
    seed_all_sources
    run bash "$SCRIPT" check
    [ "$status" -eq 1 ]
    [[ "$output" == *"rtk"*"not-wired"* ]]
    [[ "$output" == *"5 tool(s) not wired"* ]]
    [[ "$output" == *"tokenwar copilot wire"* ]]
}

@test "check reports source-missing when the tool itself is not installed" {
    mock_copilot
    # No rtk/graphify on PATH and no plugin cache: there is nothing to wire, which
    # is a different state from "installed but not wired".
    ln -sf "$(command -v node)" "$MOCK_BIN/node"
    PATH="$MOCK_BIN:/usr/bin:/bin"
    run bash "$SCRIPT" check
    [[ "$output" == *"caveman"*"source-missing"* ]]
    [[ "$output" == *"claude-mem"*"source-missing"* ]]
}

@test "check reports context-mode and pxpipe as n/a with a reason" {
    mock_copilot
    seed_all_sources
    run bash "$SCRIPT" check
    [[ "$output" == *"context-mode"*"n/a"*"version-specific interpreter path"* ]]
    [[ "$output" == *"pxpipe"*"n/a"*"GitHub's endpoint"* ]]
}

@test "check exits 0 once every installed tool is wired" {
    mock_copilot
    seed_all_sources
    run bash "$SCRIPT" wire --yes
    [ "$status" -eq 0 ]
    run bash "$SCRIPT" check
    [ "$status" -eq 0 ]
    [[ "$output" == *"Every installed tool is wired"* ]]
}

# ── wire ──────────────────────────────────────────────────────────

@test "wire uses each tool's own mechanism" {
    mock_copilot
    seed_all_sources
    run bash "$SCRIPT" wire --yes
    [ "$status" -eq 0 ]
    grep -qx "rtk init -g --copilot --auto-patch" "$CALL_LOG"
    grep -qx "graphify copilot install" "$CALL_LOG"
    # Skills go through the CLI, never a hand-rolled copy into ~/.copilot/skills.
    grep -q "^copilot skill add .*/skills/caveman/SKILL.md$" "$CALL_LOG"
    grep -q "^copilot skill add .*/skills/ponytail/SKILL.md$" "$CALL_LOG"
}

@test "wire registers claude-mem from its OWN .mcp.json definition" {
    # A hardcoded path to the current plugin version would break on the next
    # `claude plugin update`; claude-mem's published args carry a runtime locator.
    mock_copilot
    seed_all_sources
    run bash "$SCRIPT" wire --yes
    [ "$status" -eq 0 ]
    grep -qx "mcp" "$MCP_ARGS_DUMP"
    grep -qx "add" "$MCP_ARGS_DUMP"
    grep -qx "claude-mem" "$MCP_ARGS_DUMP"
    grep -qx "node" "$MCP_ARGS_DUMP"
    grep -qx -- "-e" "$MCP_ARGS_DUMP"
    grep -qx "const locator = 1; // long inline script" "$MCP_ARGS_DUMP"
}

@test "wire raises both timeouts around claude-mem's cold first search" {
    # claude-mem's first search after a cold worker path builds an index over the
    # whole memory DB and measured 2m02s. Its own client aborts at 30s by
    # default, so without this the very first MCP call always fails.
    mock_copilot
    seed_all_sources
    run bash "$SCRIPT" wire --yes
    grep -qx "CLAUDE_MEM_API_TIMEOUT_MS=180000" "$MCP_ARGS_DUMP"
    grep -qx -- "--timeout" "$MCP_ARGS_DUMP"
    grep -qx "200000" "$MCP_ARGS_DUMP"
}

@test "wire is idempotent — a second run does nothing" {
    mock_copilot
    seed_all_sources
    run bash "$SCRIPT" wire --yes
    [ "$status" -eq 0 ]
    : > "$CALL_LOG"
    run bash "$SCRIPT" wire --yes
    [ "$status" -eq 0 ]
    [[ "$output" == *"Nothing to wire"* ]]
    [ ! -s "$CALL_LOG" ]
}

@test "wire without --yes and without a tty skips instead of applying" {
    mock_copilot
    seed_all_sources
    TW_TTY="$HOME/no-such-tty" run bash "$SCRIPT" wire </dev/null
    [ "$status" -eq 0 ]
    [[ "$output" == *"No interactive terminal"* ]]
    [ ! -f "$COPILOT_HOME/hooks/rtk-rewrite.json" ]
}

@test "wire only touches the tools that are actually missing" {
    mock_copilot
    seed_all_sources
    # rtk already wired by hand → the run must not re-invoke its installer.
    mkdir -p "$COPILOT_HOME/hooks"
    echo '{"version":1}' > "$COPILOT_HOME/hooks/rtk-rewrite.json"
    run bash "$SCRIPT" wire --yes
    [ "$status" -eq 0 ]
    ! grep -q "^rtk init" "$CALL_LOG"
    grep -qx "graphify copilot install" "$CALL_LOG"
}

@test "unknown action exits 2 with usage" {
    mock_copilot
    run bash "$SCRIPT" bogus
    [ "$status" -eq 2 ]
    [[ "$output" == *"Usage:"* ]]
}

@test "dispatcher routes the copilot subcommand" {
    mock_copilot
    seed_all_sources
    run bash "$BATS_TEST_DIRNAME/../scripts/tokenwar.sh" copilot check
    [[ "$output" == *"# /tokenwar copilot"* ]]
}
