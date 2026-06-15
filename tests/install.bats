#!/usr/bin/env bats
# Tests for install.sh --with-plugins — verifies the opt-in plugin install path
# and the anti-clobber re-enable. Mocks `git` (no-op) and `claude` (records args).

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../install.sh"
    [ -f "$SCRIPT" ] || skip "install.sh not found"

    MOCK_BIN="$(mktemp -d)"
    export ORIG_PATH="$PATH"
    export PATH="$MOCK_BIN:$PATH"          # keeps real node; shadows git + claude
    export HOME="$(mktemp -d)"
    export CLAUDE_LOG="$HOME/claude-calls.log"

    # Fake existing checkout so install.sh takes the `git pull` path (no clone).
    export TOKENWAR_DIR="$HOME/.claude/skills/tokenwar"
    mkdir -p "$TOKENWAR_DIR/.git" "$TOKENWAR_DIR/scripts"
    printf '#!/usr/bin/env bash\n' > "$TOKENWAR_DIR/scripts/dummy.sh"

    printf '#!/usr/bin/env bash\nexit 0\n' > "$MOCK_BIN/git"
    chmod +x "$MOCK_BIN/git"
}

teardown() {
    rm -rf "$MOCK_BIN" "$HOME"
    export PATH="$ORIG_PATH"
}

# Default claude mock: records every invocation, returns an empty plugin list.
mock_claude_empty() {
    cat > "$MOCK_BIN/claude" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$CLAUDE_LOG"
if [[ "\$1 \$2 \$3" == "plugin list --json" ]]; then echo '[]'; fi
exit 0
EOF
    chmod +x "$MOCK_BIN/claude"
}

@test "--with-plugins installs+enables the 4 plugins incl. ponytail" {
    mock_claude_empty
    run bash "$SCRIPT" --with-plugins
    [ "$status" -eq 0 ]
    grep -q "plugin marketplace add DietrichGebert/ponytail" "$CLAUDE_LOG"
    grep -q "plugin install ponytail@ponytail" "$CLAUDE_LOG"
    grep -q "plugin enable ponytail@ponytail" "$CLAUDE_LOG"
    grep -q "plugin install context-mode@context-mode" "$CLAUDE_LOG"
}

@test "bare install (no flag) never touches plugins — opt-in only" {
    mock_claude_empty
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [ ! -f "$CLAUDE_LOG" ] || ! grep -q "plugin install" "$CLAUDE_LOG"
}

@test "--with-plugins re-enables a plugin clobbered by the first enable" {
    # Stateful mock: extern@mp is enabled until one of OUR plugins is enabled,
    # which flips it to disabled (the documented enable-clobber). install.sh must
    # detect the flip and re-enable extern@mp.
    cat > "$MOCK_BIN/claude" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$CLAUDE_LOG"
STATE="$HOME/.clobber-state"
if [[ "\$1 \$2 \$3" == "plugin list --json" ]]; then
    if [[ -f "\$STATE" ]]; then echo '[{"id":"extern@mp","enabled":false}]';
    else echo '[{"id":"extern@mp","enabled":true}]'; fi
    exit 0
fi
if [[ "\$1" == "plugin" && "\$2" == "enable" && "\$3" != "extern@mp" ]]; then : > "\$STATE"; fi
exit 0
EOF
    chmod +x "$MOCK_BIN/claude"

    run bash "$SCRIPT" --with-plugins
    [ "$status" -eq 0 ]
    grep -q "plugin enable extern@mp" "$CLAUDE_LOG"
    [[ "$output" == *"re-enabling extern@mp"* ]]
}

@test "unknown argument exits non-zero" {
    mock_claude_empty
    run bash "$SCRIPT" --bogus
    [ "$status" -ne 0 ]
}
