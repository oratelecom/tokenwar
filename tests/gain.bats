#!/usr/bin/env bats
# Tests for gain.sh — aggregates per-tool token savings.

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../scripts/gain.sh"
    [ -x "$SCRIPT" ] || skip "gain.sh not executable"

    export HOME="$(mktemp -d)"
    MOCK_BIN="$(mktemp -d)"
    export ORIG_PATH="$PATH"
    export PATH="$MOCK_BIN:$PATH"
    mkdir -p "$HOME/.claude/perfia"
}

teardown() {
    rm -rf "$HOME" "$MOCK_BIN"
    export PATH="$ORIG_PATH"
}

mock_rtk() {
    cat > "$MOCK_BIN/rtk" <<EOF
#!/usr/bin/env bash
[[ "\$1" == "gain" ]] && cat <<RTKOUT
RTK Token Savings
Total commands:    18956
Tokens saved:      44.7M (68.3%)
RTKOUT
EOF
    chmod +x "$MOCK_BIN/rtk"
}

@test "RTK parsed from rtk gain output" {
    mock_rtk
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"RTK"*"44.7M"* ]]
}

@test "TOTAL line present" {
    mock_rtk
    run bash "$SCRIPT"
    [[ "$output" == *"TOTAL"* ]]
}

@test "claude-mem N/A when gain.jsonl empty" {
    mock_rtk
    # gain.jsonl exists but no entries for claude-mem
    : > "$HOME/.claude/perfia/gain.jsonl"
    run bash "$SCRIPT"
    [[ "$output" == *"claude-mem"*"N/A"* ]]
}

@test "claude-mem reads entries from gain.jsonl" {
    mock_rtk
    cat > "$HOME/.claude/perfia/gain.jsonl" <<'EOF'
{"tool":"claude-mem","bytes_in":4000,"bytes_out":1000}
{"tool":"claude-mem","bytes_in":8000,"bytes_out":2000}
EOF
    run bash "$SCRIPT"
    # 4000-1000 + 8000-2000 = 9000 bytes / 4 chars-per-token = 2250 tokens → "2.3K"
    [[ "$output" == *"claude-mem"*"2.3K"* || "$output" == *"claude-mem"*"2.2K"* ]]
}

@test "ctx_stats absence → context-mode shows N/A" {
    mock_rtk
    unset CTX_STATS_JSON
    run bash "$SCRIPT"
    [[ "$output" == *"context-mode"*"N/A"* ]]
}

@test "rtk absent → RTK shows N/A" {
    # no rtk binary
    run bash "$SCRIPT"
    [[ "$output" == *"RTK"*"N/A"* ]]
}
