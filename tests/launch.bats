#!/usr/bin/env bats
# Tests for tokenwar-launch.sh — the codex/gemini/kimi/opencode launch banner.
# The banner must stay SILENT for non-interactive launches (no TTY, exec, -p).

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../scripts/tokenwar-launch.sh"
    [ -x "$SCRIPT" ] || skip "tokenwar-launch.sh not executable"
    export HOME="$(mktemp -d)"
    mkdir -p "$HOME/.claude/tokenwar"
}

teardown() {
    rm -rf "$HOME"
}

@test "no TTY on stdout → no banner, exit 0" {
    run bash "$SCRIPT" codex </dev/null
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "codex exec subcommand → no banner even if forced TTY-like" {
    # exec is in the non-interactive list; piped output guarantees no -t 1 anyway
    run bash "$SCRIPT" codex exec "do something" </dev/null
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "gemini -p headless flag → no banner" {
    run bash "$SCRIPT" gemini -p "summarize" </dev/null
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "kimi -p headless flag → no banner" {
    run bash "$SCRIPT" kimi -p "summarize" </dev/null
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "opencode run headless subcommand → no banner" {
    run bash "$SCRIPT" opencode run "summarize" </dev/null
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "provider arg is accepted without error" {
    run bash "$SCRIPT" gemini </dev/null
    [ "$status" -eq 0 ]
}

@test "provider-only update cache does not offer managed upgrade" {
    cat > "$HOME/.claude/tokenwar/upgrade-check.json" <<'EOF'
{"tools":{"context-mode":{"state":"up-to-date"},"claude-mem":{"state":"up-to-date"},"caveman":{"state":"up-to-date"},"rtk":{"state":"up-to-date"},"pxpipe":{"state":"up-to-date"}},"providers":{"codex":{"state":"update-available"}}}
EOF

    run bash "$SCRIPT" codex </dev/null
    [ "$status" -eq 0 ]
    [[ "$output" != *"Upgrade now?"* ]]
    [[ "$output" != *"update available"* ]]
}

@test "interactive launch with pending tool update shows status hint without upgrade prompt" {
    command -v script >/dev/null 2>&1 || skip "script command not available"
    cat > "$HOME/.claude/tokenwar/upgrade-check.json" <<'EOF'
{"tools":{"context-mode":{"state":"up-to-date"},"claude-mem":{"state":"up-to-date"},"caveman":{"state":"update-available"},"rtk":{"state":"up-to-date"},"pxpipe":{"state":"up-to-date"}},"providers":{"codex":{"state":"up-to-date"}}}
EOF

    run script -qfec "env HOME='$HOME' bash '$SCRIPT' codex" /dev/null
    [ "$status" -eq 0 ]
    [[ "$output" == *"/tokenwar upgrade"* ]]
    [[ "$output" != *"Upgrade now?"* ]]
}

# ── GitHub Copilot CLI ────────────────────────────────────────────
#
# These run under a real pty (`script -qfec`). Without one, `[[ -t 1 ]]` is false
# and the banner is suppressed no matter what the subcommand/flag filter says —
# the test would pass against a launcher that knows nothing about Copilot.

copilot_launch() {
    command -v script >/dev/null 2>&1 || skip "script command not available"
    run script -qfec "env HOME='$HOME' bash '$SCRIPT' copilot $*" /dev/null
}

@test "copilot -p headless flag → no banner even on a tty" {
    copilot_launch -p "summarize"
    [ "$status" -eq 0 ]
    [[ "$output" != *"tokenwar"* ]]
}

@test "copilot --acp (Agent Client Protocol server) → no banner on a tty" {
    # --acp turns the CLI into a machine channel; a banner on stdout corrupts it.
    copilot_launch --acp
    [ "$status" -eq 0 ]
    [[ "$output" != *"tokenwar"* ]]
}

@test "copilot management subcommands → no banner on a tty" {
    for sub in mcp skill plugin update version login; do
        copilot_launch "$sub" list
        [ "$status" -eq 0 ]
        [[ "$output" != *"tokenwar"* ]]
    done
}

@test "copilot --version → no banner on a tty" {
    copilot_launch --version
    [ "$status" -eq 0 ]
    [[ "$output" != *"tokenwar"* ]]
}

@test "interactive copilot launch prints the banner naming the provider" {
    copilot_launch
    [ "$status" -eq 0 ]
    [[ "$output" == *"tokenwar"*"copilot"* ]]
    [[ "$output" == *"tokenwar status"* ]]
}
