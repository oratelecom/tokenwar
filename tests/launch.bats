#!/usr/bin/env bats
# Tests for tokenwar-launch.sh — the codex/gemini/kimi launch banner.
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

@test "provider arg is accepted without error" {
    run bash "$SCRIPT" gemini </dev/null
    [ "$status" -eq 0 ]
}
