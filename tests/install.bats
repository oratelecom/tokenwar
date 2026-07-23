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
    export NPM_LOG="$HOME/npm-calls.log"

    # Fake existing checkout so install.sh takes the `git pull` path (no clone).
    export TOKENWAR_DIR="$HOME/.claude/skills/tokenwar"
    mkdir -p "$TOKENWAR_DIR/.git" "$TOKENWAR_DIR/scripts"
    printf '#!/usr/bin/env bash\n' > "$TOKENWAR_DIR/scripts/dummy.sh"

    printf '#!/usr/bin/env bash\nexit 0\n' > "$MOCK_BIN/git"
    chmod +x "$MOCK_BIN/git"

    # Mock rtk (records args) so tests never touch the real rtk / real settings.
    export RTK_LOG="$HOME/rtk-calls.log"
    cat > "$MOCK_BIN/rtk" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$RTK_LOG"
[[ "\$1" == "--version" ]] && echo "rtk 0.0.0-test"
exit 0
EOF
    chmod +x "$MOCK_BIN/rtk"
}

# Write a fake rtk binary at $1 that records its args to $RTK_LOG.
make_fake_rtk() {
    cat > "$1" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$RTK_LOG"
[[ "\$1" == "--version" ]] && echo "rtk 9.9.9"
exit 0
EOF
    chmod +x "$1"
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

@test "bare install wires codex gemini and kimi launch wrappers" {
    mock_claude_empty
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    grep -q "codex()" "$HOME/.bashrc"
    grep -q "gemini()" "$HOME/.bashrc"
    grep -q "kimi()" "$HOME/.bashrc"
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

@test "--with-plugins wires the rtk hook when the rtk binary is present" {
    mock_claude_empty
    run bash "$SCRIPT" --with-plugins
    [ "$status" -eq 0 ]
    grep -q "init -g" "$RTK_LOG"
}

@test "--with-plugins warns + skips the hook when the rtk binary is absent" {
    mock_claude_empty
    rm -f "$MOCK_BIN/rtk"                       # drop our mock
    ln -s "$(command -v node)" "$MOCK_BIN/node" # keep node reachable
    PATH="$MOCK_BIN:/usr/bin:/bin"              # excludes ~/.cargo/bin → real rtk not found
    run bash "$SCRIPT" --with-plugins
    [ "$status" -eq 0 ]
    [[ "$output" == *"rtk binary not found"* ]]
    [ ! -f "$RTK_LOG" ]
}

@test "--with-rtk installs rtk via the official prebuilt installer when absent" {
    rm -f "$MOCK_BIN/rtk"                          # rtk not yet installed
    ln -s "$(command -v node)" "$MOCK_BIN/node"
    PATH="$MOCK_BIN:/usr/bin:/bin"                 # excludes ~/.cargo/bin → real rtk hidden
    make_fake_rtk "$HOME/fake-rtk"
    # Mock curl = rtk's official installer: drops the binary into ~/.local/bin.
    cat > "$MOCK_BIN/curl" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$HOME/curl-calls.log"
mkdir -p "$HOME/.local/bin"
cp "$HOME/fake-rtk" "$HOME/.local/bin/rtk"
exit 0
EOF
    chmod +x "$MOCK_BIN/curl"

    run bash "$SCRIPT" --with-rtk
    [ "$status" -eq 0 ]
    grep -q "rtk-ai/rtk" "$HOME/curl-calls.log"     # called the official installer
    [ -x "$HOME/.local/bin/rtk" ]                    # binary landed
    grep -q "init -g" "$RTK_LOG"                     # hook wired afterwards
}

@test "--with-rtk skips install when rtk already present, still wires the hook" {
    mock_claude_empty
    run bash "$SCRIPT" --with-rtk
    [ "$status" -eq 0 ]
    [[ "$output" == *"already installed"* ]]
    grep -q "init -g" "$RTK_LOG"
}

@test "--with-pxpipe installs pinned pxpipe-proxy package when absent" {
    mock_claude_empty
    rm -f "$MOCK_BIN/pxpipe"
    ln -s "$(command -v node)" "$MOCK_BIN/node"
    cat > "$MOCK_BIN/npm" <<EOF
#!/usr/bin/env bash
if [[ "\$1 \$2 \$3" == "config get prefix" ]]; then
    echo "$HOME/.local"
    exit 0
fi
echo "\$*" >> "$NPM_LOG"
mkdir -p "$HOME/.local/bin"
cat > "$HOME/.local/bin/pxpipe" <<'PXPIPE'
#!/usr/bin/env bash
[[ "$1" == "--version" ]] && echo "0.10.0"
PXPIPE
chmod +x "$HOME/.local/bin/pxpipe"
exit 0
EOF
    chmod +x "$MOCK_BIN/npm"
    PATH="$MOCK_BIN:/usr/bin:/bin"
    run bash "$SCRIPT" --with-pxpipe
    [ "$status" -eq 0 ]
    grep -q "install -g pxpipe-proxy@0.10.0" "$NPM_LOG"
    [ -x "$HOME/.local/bin/pxpipe" ]
}

@test "--all installs plugins AND handles rtk and pxpipe" {
    mock_claude_empty
    ln -s "$(command -v node)" "$MOCK_BIN/node"
    cat > "$MOCK_BIN/npm" <<EOF
#!/usr/bin/env bash
if [[ "\$1 \$2 \$3" == "config get prefix" ]]; then
    echo "$HOME/.local"
    exit 0
fi
echo "\$*" >> "$NPM_LOG"
exit 0
EOF
    chmod +x "$MOCK_BIN/npm"
    PATH="$MOCK_BIN:/usr/bin:/bin"
    run bash "$SCRIPT" --all
    [ "$status" -eq 0 ]
    grep -q "plugin install ponytail@ponytail" "$CLAUDE_LOG"
    grep -q "init -g" "$RTK_LOG"
    grep -q "install -g pxpipe-proxy@0.10.0" "$NPM_LOG"
}

@test "unknown argument exits non-zero" {
    mock_claude_empty
    run bash "$SCRIPT" --bogus
    [ "$status" -ne 0 ]
}
