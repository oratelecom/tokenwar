#!/usr/bin/env bats
# Tests for scan.sh — local log opportunity estimator.

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../scripts/scan.sh"
    DISPATCHER="$BATS_TEST_DIRNAME/../scripts/tokenwar.sh"
    [ -x "$SCRIPT" ] || skip "scan.sh not executable"

    export HOME="$(mktemp -d)"
    export TOKENWAR_SCAN_SKIP_STATUS=1
    export TOKENWAR_SCAN_MAX_FILES=20
    export TOKENWAR_SCAN_MAX_BYTES_PER_FILE=20000
    export TOKENWAR_SCAN_MIN_RECOMMENDATION_TOKENS=1
}

teardown() {
    rm -rf "$HOME"
}

write_codex_log() {
    mkdir -p "$HOME/.codex"
    cat > "$HOME/.codex/history.jsonl" <<'EOF'
{"text":"run rg --files then sed -n '1,220p' scripts/tokenwar.sh"}
{"text":"gh api repos/example/project/pulls/1/comments --paginate"}
{"text":"curl -fsSL https://example.test/large.json"}
{"text":"apply_patch added 120 insertions and git diff showed a large generated file"}
{"text":"resume the previous session, read AGENTS.md and coding-rules.md again"}
EOF
}

@test "scan recommends shell, context, memory, and code tools from local logs" {
    write_codex_log

    run bash "$SCRIPT" --client codex
    [ "$status" -eq 0 ]
    [[ "$output" == *"# /tokenwar scan"* ]]
    [[ "$output" == *"decision"* ]]
    [[ "$output" == *"RTK"* ]]
    [[ "$output" == *"Probe / Stacklit / Serena / Graphify"* ]]
    [[ "$output" == *"context-mode alternative"* ]]
    [[ "$output" == *"claude-mem / OpenWiki"* ]]
    [[ "$output" == *"ponytail"* ]]
}

@test "scan json mode emits clients and recommendations" {
    write_codex_log

    run bash "$SCRIPT" --client codex --json
    [ "$status" -eq 0 ]
    [[ "$output" == *'"clients"'* ]]
    [[ "$output" == *'"id": "codex"'* ]]
    [[ "$output" == *'"recommendations"'* ]]
}

@test "dispatcher routes scan subcommand" {
    write_codex_log

    run bash "$DISPATCHER" scan --client codex
    [ "$status" -eq 0 ]
    [[ "$output" == *"# /tokenwar scan"* ]]
}
