#!/usr/bin/env bats
# Functional proof for tokenwar's RTK/OpenCode integration.

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../scripts/opencode-functional-test.sh"
}

@test "real rtk installs and proves the opencode plugin path" {
    command -v rtk >/dev/null 2>&1 || skip "rtk required for functional opencode test"
    command -v opencode >/dev/null 2>&1 || skip "opencode required for functional opencode test"

    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[ok] rtk init -g --opencode"* ]]
    [[ "$output" == *"[ok] opencode config references RTK plugin"* ]]
    [[ "$output" == *"[ok] rtk rewrite: git status -> rtk git status"* ]]
}
