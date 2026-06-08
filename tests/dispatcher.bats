#!/usr/bin/env bats
# Tests for tokenwar.sh — the cross-CLI dispatcher.

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../scripts/tokenwar.sh"
    [ -x "$SCRIPT" ] || skip "tokenwar.sh not executable"
}

@test "help lists the commands" {
    run bash "$SCRIPT" help
    [ "$status" -eq 0 ]
    [[ "$output" == *"status"* ]]
    [[ "$output" == *"gain"* ]]
    [[ "$output" == *"upgrade"* ]]
}

@test "unknown command exits 2 with usage" {
    run bash "$SCRIPT" bogus
    [ "$status" -eq 2 ]
    [[ "$output" == *"unknown command"* ]]
}

@test "check subcommand runs the checker" {
    run bash "$SCRIPT" check
    # check.sh prints a verdict; exit code may be 0/1 depending on environment
    [[ "$output" == *"Verdict"* ]]
}
