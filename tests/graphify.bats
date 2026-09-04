#!/usr/bin/env bats
# Tests for graphify — the 7th managed tool (repo/doc structure lane).
#
# graphify is a PyPI package (`graphifyy`) exposing a `graphify` CLI plus a skill
# that `graphify install` copies into the assistant's config dir. It is NOT a
# Claude Code plugin, so it takes the same non-plugin path as rtk and pxpipe:
# detected by binary + skill file, upgraded through its own installer, refused by
# `tokenwar enable|disable`.

setup() {
    STATUSLINE="$BATS_TEST_DIRNAME/../scripts/tokenwar-statusline.sh"
    UPGRADE="$BATS_TEST_DIRNAME/../scripts/upgrade.sh"
    CHECK_UPDATES="$BATS_TEST_DIRNAME/../scripts/check-updates.sh"
    TOGGLE="$BATS_TEST_DIRNAME/../scripts/toggle.sh"

    MOCK_BIN="$(mktemp -d)"
    export ORIG_PATH="$PATH"
    export PATH="$MOCK_BIN:$PATH"

    export HOME="$(mktemp -d)"
    mkdir -p "$HOME/.claude/tokenwar"
    # Hermetic cache dir for the statusline's 30s plugin/rtk caches.
    export TMPDIR="$HOME/tmp"
    mkdir -p "$TMPDIR"

    export CALL_LOG="$HOME/calls.log"

    GREEN=$'\033[32m'
    RED=$'\033[31m'
    YELLOW=$'\033[33m'
}

teardown() {
    # Restore PATH FIRST: a test may have shrunk it to the mock dir, and the
    # cleanup below still needs the real coreutils.
    export PATH="$ORIG_PATH"
    rm -rf "$MOCK_BIN" "$HOME"
}

write_update_cache() {
    cat > "$HOME/.claude/tokenwar/upgrade-check.json"
}

uptodate_cache() {
    write_update_cache <<'EOF'
{"refresh_ok":true,"tools":{
  "context-mode":{"state":"up-to-date"},
  "claude-mem":{"state":"up-to-date"},
  "caveman":{"state":"up-to-date"},
  "rtk":{"state":"up-to-date"},
  "pxpipe":{"state":"up-to-date"},
  "graphify":{"state":"up-to-date"}
}}
EOF
}

mock_graphify_cli() {
    cat > "$MOCK_BIN/graphify" <<EOF
#!/usr/bin/env bash
echo "graphify \$*" >> "$CALL_LOG"
[[ "\$1" == "--version" ]] && echo "graphify 0.9.53"
exit 0
EOF
    chmod +x "$MOCK_BIN/graphify"
}

# Narrow PATH to the mocks + system dirs so the host's own graphify/cargo/uv
# never leaks into an assertion. node and curl are symlinked in first because
# the scripts need them after the shrink.
isolate_path() {
    ln -sf "$(command -v node)" "$MOCK_BIN/node"
    command -v curl >/dev/null 2>&1 && ln -sf "$(command -v curl)" "$MOCK_BIN/curl"
    PATH="$MOCK_BIN:/usr/bin:/bin"
}

# ── statusline badge ──────────────────────────────────────────────

@test "statusline renders a green graphify badge with its version" {
    uptodate_cache
    mock_graphify_cli
    run bash "$STATUSLINE" <<<'{}'
    [ "$status" -eq 0 ]
    [[ "$output" == *"${GREEN}[graphify 0.9.53]"* ]]
}

@test "statusline renders graphify red when the CLI is absent" {
    uptodate_cache
    isolate_path
    run bash "$STATUSLINE" <<<'{}'
    [ "$status" -eq 0 ]
    [[ "$output" == *"${RED}[graphify -]"* ]]
}

@test "statusline marks graphify with the update arrow and counts it in the summary" {
    write_update_cache <<'EOF'
{"refresh_ok":true,"tools":{
  "context-mode":{"state":"up-to-date"},
  "claude-mem":{"state":"up-to-date"},
  "caveman":{"state":"up-to-date"},
  "rtk":{"state":"up-to-date"},
  "pxpipe":{"state":"up-to-date"},
  "graphify":{"state":"update-available"}
}}
EOF
    mock_graphify_cli
    run bash "$STATUSLINE" <<<'{}'
    [ "$status" -eq 0 ]
    [[ "$output" == *"graphify 0.9.53 ${YELLOW}⬆"* ]]
    [[ "$output" == *"⬆ 1 update · /tokenwar upgrade"* ]]
}

# ── check-updates: latest from PyPI ───────────────────────────────

@test "check-updates reads graphify's latest version from the PyPI JSON API" {
    mock_graphify_cli
    isolate_path
    # Serve the registry payload from disk so the test never touches the network
    # and still exercises the real curl → node parse path.
    cat > "$HOME/pypi.json" <<'EOF'
{"info":{"name":"graphifyy","version":"9.9.9"},"releases":{}}
EOF
    TW_GRAPHIFY_PYPI_URL="file://$HOME/pypi.json" run bash "$CHECK_UPDATES" --force
    [[ "$output" == *"graphify"*"0.9.53"*"9.9.9"*"update-available"* ]]
}

@test "check-updates degrades graphify to unknown when the registry is unreachable" {
    mock_graphify_cli
    isolate_path
    TW_GRAPHIFY_PYPI_URL="file://$HOME/does-not-exist.json" run bash "$CHECK_UPDATES" --force
    # Honest unknown — never a fabricated "up-to-date" verdict.
    [[ "$output" == *"graphify"*"0.9.53"*"unknown"* ]]
}

# ── upgrade routing ───────────────────────────────────────────────

@test "upgrade lists graphify only when the cache flags it" {
    write_update_cache <<'EOF'
{"tools":{"context-mode":{"state":"up-to-date"},"claude-mem":{"state":"up-to-date"},"caveman":{"state":"up-to-date"},"rtk":{"state":"up-to-date"},"pxpipe":{"state":"up-to-date"},"graphify":{"state":"update-available"}}}
EOF
    run bash "$UPGRADE" </dev/null
    [ "$status" -eq 0 ]
    [[ "$output" == *"graphify"* ]]
    [[ "$output" != *"pxpipe"* ]]
}

@test "upgrade uses uv tool when uv owns the package, then refreshes the skill" {
    write_update_cache <<'EOF'
{"tools":{"graphify":{"state":"update-available"}}}
EOF
    mock_graphify_cli
    cat > "$MOCK_BIN/uv" <<EOF
#!/usr/bin/env bash
echo "uv \$*" >> "$CALL_LOG"
if [[ "\$1 \$2" == "tool list" ]]; then
    echo "graphifyy v0.9.51"
    echo "- graphify"
fi
exit 0
EOF
    chmod +x "$MOCK_BIN/uv"

    run bash "$UPGRADE" --yes
    [ "$status" -eq 0 ]
    grep -qx "uv tool upgrade graphifyy" "$CALL_LOG"
    # A version bump alone leaves the assistant on the previous playbook.
    grep -qx "graphify install" "$CALL_LOG"
}

@test "upgrade falls back to pipx when uv does not own the package" {
    write_update_cache <<'EOF'
{"tools":{"graphify":{"state":"update-available"}}}
EOF
    mock_graphify_cli
    cat > "$MOCK_BIN/uv" <<EOF
#!/usr/bin/env bash
echo "uv \$*" >> "$CALL_LOG"
[[ "\$1 \$2" == "tool list" ]] && echo "some-other-tool v1.0.0"
exit 0
EOF
    chmod +x "$MOCK_BIN/uv"
    cat > "$MOCK_BIN/pipx" <<EOF
#!/usr/bin/env bash
echo "pipx \$*" >> "$CALL_LOG"
[[ "\$1" == "list" ]] && echo "graphifyy 0.9.51"
exit 0
EOF
    chmod +x "$MOCK_BIN/pipx"

    run bash "$UPGRADE" --yes
    [ "$status" -eq 0 ]
    grep -qx "pipx upgrade graphifyy" "$CALL_LOG"
    ! grep -q "uv tool upgrade" "$CALL_LOG"
}

@test "upgrade never runs pip against a uv-owned graphify" {
    # Regression guard: `pip install -U` writes to a different environment than
    # uv's isolated venv, so the graphify on PATH would stay on the old version
    # while the upgrade reported success.
    write_update_cache <<'EOF'
{"tools":{"graphify":{"state":"update-available"}}}
EOF
    mock_graphify_cli
    cat > "$MOCK_BIN/uv" <<EOF
#!/usr/bin/env bash
echo "uv \$*" >> "$CALL_LOG"
[[ "\$1 \$2" == "tool list" ]] && echo "graphifyy v0.9.51"
exit 0
EOF
    chmod +x "$MOCK_BIN/uv"
    cat > "$MOCK_BIN/pip" <<EOF
#!/usr/bin/env bash
echo "pip \$*" >> "$CALL_LOG"
exit 0
EOF
    chmod +x "$MOCK_BIN/pip"

    run bash "$UPGRADE" --yes
    [ "$status" -eq 0 ]
    ! grep -q "^pip install" "$CALL_LOG"
}

@test "upgrade reports failure when no python installer is available" {
    write_update_cache <<'EOF'
{"tools":{"graphify":{"state":"update-available"}}}
EOF
    # Strict isolation: MOCK_BIN only. /usr/bin often ships a system `pip`, and
    # letting it through would exercise the pip branch instead of the
    # no-installer branch this test is about. bash and node are linked in
    # because the script still has to start and parse its cache.
    ln -sf "$(command -v bash)" "$MOCK_BIN/bash"
    ln -sf "$(command -v node)" "$MOCK_BIN/node"
    PATH="$MOCK_BIN"
    run bash "$UPGRADE" --yes
    [ "$status" -eq 1 ]
    [[ "$output" == *"cannot update graphify"* ]]
}

# ── toggle refuses graphify (not a plugin) ────────────────────────

@test "toggle refuses graphify and points at graphify install/uninstall" {
    run bash "$TOGGLE" disable graphify
    [ "$status" -eq 3 ]
    [[ "$output" == *"not a Claude Code plugin"* ]]
    [[ "$output" == *"graphify install"* ]]
    [[ "$output" == *"graphify uninstall"* ]]
}
