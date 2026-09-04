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

write_apply_fixtures() {
    cat > "$HOME/status.sh" <<'EOF'
#!/usr/bin/env bash
cat <<'JSON'
{
  "tools": {
    "context-mode": {"state": "OK"},
    "claude-mem": {"state": "OK"},
    "rtk": {"state": "OK"},
    "caveman": {"state": "installed-disabled"},
    "ponytail": {"state": "OK"},
    "pxpipe": {"state": "OK"}
  }
}
JSON
EOF
    cat > "$HOME/toggle.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s %s\n' "$1" "$2" >> "$HOME/apply.log"
printf 'enabled %s\n' "$2"
EOF
    chmod +x "$HOME/status.sh" "$HOME/toggle.sh"
    export TOKENWAR_SCAN_SKIP_STATUS=0
    export TOKENWAR_STATUS_SCRIPT="$HOME/status.sh"
    export TOKENWAR_TOGGLE_SCRIPT="$HOME/toggle.sh"
}

@test "scan recommends shell, context, memory, and code tools from local logs" {
    write_codex_log

    run bash "$SCRIPT" --client codex
    [ "$status" -eq 0 ]
    [[ "$output" == *"# /tokenwar scan"* ]]
    [[ "$output" == *"decision"* ]]
    [[ "$output" == *"RTK"* ]]
    [[ "$output" == *"graphify"* ]]
    [[ "$output" == *"Probe / Stacklit / Serena"* ]]
    [[ "$output" == *"context-mode alternative"* ]]
    [[ "$output" == *"claude-mem / OpenWiki"* ]]
    [[ "$output" == *"ponytail"* ]]
}

@test "scan apply asks before enabling applicable recommendations" {
    write_codex_log
    write_apply_fixtures

    export TOKENWAR_SCAN_CONFIRM=yes
    run bash "$SCRIPT" --client codex --apply
    [ "$status" -eq 0 ]
    [[ "$output" == *"Apply recommended TokenWar changes?"* ]]
    [[ "$output" == *"enable caveman"* ]]
    [[ "$output" == *"enabled caveman"* ]]
    [ "$(cat "$HOME/apply.log")" = "enable caveman" ]
}

@test "scan apply does nothing when declined" {
    write_codex_log
    write_apply_fixtures

    export TOKENWAR_SCAN_CONFIRM=no
    run bash "$SCRIPT" --client codex --apply
    [ "$status" -eq 0 ]
    [[ "$output" == *"Apply skipped"* ]]
    [ ! -f "$HOME/apply.log" ]
}

@test "scan apply yes flag enables without prompting" {
    write_codex_log
    write_apply_fixtures

    run bash "$SCRIPT" --client codex --apply --yes
    [ "$status" -eq 0 ]
    [[ "$output" == *"Applying recommended TokenWar changes"* ]]
    [[ "$output" != *"Apply recommended TokenWar changes?"* ]]
    [ "$(cat "$HOME/apply.log")" = "enable caveman" ]
}

@test "scan apply refuses json mode" {
    write_codex_log

    run bash "$SCRIPT" --client codex --apply --json
    [ "$status" -eq 2 ]
    [[ "$output" == *"--apply cannot be combined with --json"* ]]
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

@test "scan detects GitHub Copilot CLI logs as a client" {
    # Copilot writes session state under ~/.copilot; the scan must pick it up
    # like any other local client, without a CLI on PATH.
    mkdir -p "$HOME/.copilot/session-state/abc"
    cat > "$HOME/.copilot/session-state/abc/events.jsonl" <<'EOF'
{"text":"rg --files then sed -n '1,220p' scripts/tokenwar.sh"}
{"text":"git diff and gh pr view produced a large payload"}
EOF
    run bash "$SCRIPT" --client copilot
    [ "$status" -eq 0 ]
    # The client row is keyed by id and reports how many log files were read —
    # asserting the file count proves the root was scanned, not just listed.
    [[ "$output" == *"copilot"*" 1 "* ]]
    [[ "$output" == *"repo discovery signals"* ]]
}

@test "scan honours TOKENWAR_COPILOT_LOG_ROOT" {
    local root="$HOME/elsewhere"
    mkdir -p "$root"
    cat > "$root/events.jsonl" <<'EOF'
{"text":"rg --files and grep -rn across the repo"}
EOF
    TOKENWAR_COPILOT_LOG_ROOT="$root" run bash "$SCRIPT" --client copilot
    [ "$status" -eq 0 ]
    [[ "$output" == *"copilot"*" 1 "* ]]
}

@test "scan --json exposes copilot as a known client" {
    mkdir -p "$HOME/.copilot"
    printf '{"text":"rg --files"}\n' > "$HOME/.copilot/events.jsonl"
    run bash "$SCRIPT" --client copilot --json
    [ "$status" -eq 0 ]
    echo "$output" | node -e '
        let s = "";
        process.stdin.on("data", d => s += d).on("end", () => {
            const j = JSON.parse(s);
            const ids = (j.clients || []).map(c => c.id);
            if (!ids.includes("copilot")) process.exit(1);
        });
    '
}
