#!/usr/bin/env bats
# Tests for upgrade.sh interactive confirm handling — the answer that the user
# gives at the "Upgrade now? [y/N]" prompt must be honored exactly.
#
# Regression target: the old flow read the confirm from a hardcoded /dev/tty,
# which is unavailable under the Bash tool / CI, so every interactive answer
# collapsed to "empty → Skipped" and the caller re-asked in a loop. upgrade.sh
# now reads the confirm from $TW_TTY (default /dev/tty), so tests can feed a
# real answer through a file and assert it is respected.
#
# Cases covered: YES applies, NO declines, empty declines, an old→new version is
# surfaced at the prompt, and the no-tty path still skips safely.

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../scripts/upgrade.sh"
    [ -x "$SCRIPT" ] || skip "upgrade.sh not executable"
    export HOME="$(mktemp -d)"
    mkdir -p "$HOME/.claude/tokenwar"
    MOCK_BIN="$(mktemp -d)"
    export ORIG_PATH="$PATH"
    export PATH="$MOCK_BIN:$PATH"
    export CLAUDE_LOG="$HOME/claude-calls.log"
    export ANSWER_FILE="$HOME/answer.txt"
}

teardown() {
    rm -rf "$HOME" "$MOCK_BIN"
    export PATH="$ORIG_PATH"
}

# Mock claude: records args; reports caveman as user-scoped so upgrade_plugin runs.
mock_claude() {
    cat > "$MOCK_BIN/claude" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$CLAUDE_LOG"
if [[ "\$1 \$2 \$3" == "plugin list --json" ]]; then
cat <<'JSON'
[{"id":"caveman@caveman","scope":"user","enabled":true}]
JSON
fi
exit 0
EOF
    chmod +x "$MOCK_BIN/claude"
}

# Cache flagging caveman as an available update from an OLD version to a NEW one.
write_old_version_cache() {
    cat > "$HOME/.claude/tokenwar/upgrade-check.json" <<'EOF'
{"tools":{"context-mode":{"state":"up-to-date"},"claude-mem":{"state":"up-to-date"},"caveman":{"state":"update-available","current":"ec83e5bace4c","latest":"11ddc0c9813c"},"rtk":{"state":"up-to-date"}}}
EOF
}

# Run the script with a canned interactive answer fed through $TW_TTY.
run_with_answer() {
    printf '%s\n' "$1" > "$ANSWER_FILE"
    TW_TTY="$ANSWER_FILE" run bash "$SCRIPT" </dev/null
}

@test "prompt appears when an update is pending (old version surfaced)" {
    mock_claude
    write_old_version_cache
    run_with_answer "n"
    [[ "$output" == *"the following tools will be updated"* ]]
    [[ "$output" == *"caveman"* ]]
    [[ "$output" == *"Upgrade now?"* ]]
}

@test "answer YES → upgrade is applied" {
    mock_claude
    write_old_version_cache
    run_with_answer "y"
    [ "$status" -eq 0 ]
    grep -q "plugin update caveman@caveman" "$CLAUDE_LOG"
}

@test "answer 'yes' (long form) → upgrade is applied" {
    mock_claude
    write_old_version_cache
    run_with_answer "yes"
    [ "$status" -eq 0 ]
    grep -q "plugin update caveman@caveman" "$CLAUDE_LOG"
}

@test "answer NO → nothing is upgraded, exit 0, says Skipped" {
    mock_claude
    write_old_version_cache
    run_with_answer "n"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Skipped"* ]]
    [ ! -f "$CLAUDE_LOG" ] || ! grep -q "plugin update" "$CLAUDE_LOG"
}

@test "answer empty (bare Enter) → declines, nothing upgraded" {
    mock_claude
    write_old_version_cache
    run_with_answer ""
    [ "$status" -eq 0 ]
    [[ "$output" == *"Skipped"* ]]
    [ ! -f "$CLAUDE_LOG" ] || ! grep -q "plugin update" "$CLAUDE_LOG"
}

@test "answer garbage (not y/yes) → declines, nothing upgraded" {
    mock_claude
    write_old_version_cache
    run_with_answer "maybe"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Skipped"* ]]
    [ ! -f "$CLAUDE_LOG" ] || ! grep -q "plugin update" "$CLAUDE_LOG"
}

@test "no tty available at all → skips safely, exit 0, no /dev/tty leak" {
    mock_claude
    write_old_version_cache
    # Point TW_TTY at a path that cannot be opened for reading.
    TW_TTY="$HOME/does-not-exist/tty" run bash "$SCRIPT" </dev/null
    [ "$status" -eq 0 ]
    [[ "$output" == *"No interactive terminal"* ]]
    [[ "$output" != *"No such device"* ]]
    [ ! -f "$CLAUDE_LOG" ] || ! grep -q "plugin update" "$CLAUDE_LOG"
}

@test "--yes bypasses the prompt entirely (answer file never read)" {
    mock_claude
    write_old_version_cache
    # A NO in the file must be ignored because --yes short-circuits the confirm.
    printf 'n\n' > "$ANSWER_FILE"
    TW_TTY="$ANSWER_FILE" run bash "$SCRIPT" --yes </dev/null
    [ "$status" -eq 0 ]
    [[ "$output" != *"Upgrade now?"* ]]
    grep -q "plugin update caveman@caveman" "$CLAUDE_LOG"
}
