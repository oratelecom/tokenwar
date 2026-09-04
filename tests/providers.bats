#!/usr/bin/env bats
# Tests for multi-provider support — Codex, Gemini, Kimi, opencode, Copilot, Claude detection.

setup() {
    GAIN_SCRIPT="$BATS_TEST_DIRNAME/../scripts/gain.sh"
    STATUS_SCRIPT="$BATS_TEST_DIRNAME/../scripts/status.sh"

    export HOME="$(mktemp -d)"
    MOCK_BIN="$(mktemp -d)"
    export ORIG_PATH="$PATH"
    export PATH="$MOCK_BIN:$PATH"
    mkdir -p "$HOME/.claude/tokenwar"
}

teardown() {
    rm -rf "$HOME" "$MOCK_BIN"
    export PATH="$ORIG_PATH"
}

# ── Provider CLI detection in status.sh ─────────────────────────

mock_claude_with_plugins() {
    cat > "$MOCK_BIN/claude" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "plugin" && "\$2" == "list" && "\$3" == "--json" ]]; then
    cat <<JSON
$1
JSON
fi
EOF
    chmod +x "$MOCK_BIN/claude"
}

mock_rtk_alive() {
    cat > "$MOCK_BIN/rtk" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == "gain" ]] && echo "Tokens saved: 1M"
[[ "$1" == "--version" ]] && echo "rtk 0.30.1"
exit 0
EOF
    chmod +x "$MOCK_BIN/rtk"
}

mock_codex() {
    cat > "$MOCK_BIN/codex" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == "--version" ]] && echo "codex-cli 0.131.0"
exit 0
EOF
    chmod +x "$MOCK_BIN/codex"
}

mock_gemini() {
    cat > "$MOCK_BIN/gemini" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == "--version" ]] && echo "0.38.2"
exit 0
EOF
    chmod +x "$MOCK_BIN/gemini"
}

mock_kimi() {
    cat > "$MOCK_BIN/kimi" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == "--version" ]] && echo "kimi-code 0.9.1"
exit 0
EOF
    chmod +x "$MOCK_BIN/kimi"
}

mock_opencode() {
    cat > "$MOCK_BIN/opencode" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == "--version" ]] && echo "1.15.4"
exit 0
EOF
    chmod +x "$MOCK_BIN/opencode"
}

# Copilot's version line ends with a full stop and is followed by an update
# notice: "GitHub Copilot CLI 1.0.83." + "Run 'copilot update'...". Both halves
# are reproduced so the parser is tested against the real shape.
mock_copilot() {
    cat > "$MOCK_BIN/copilot" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "--version" || "$1" == "-v" ]]; then
    echo "GitHub Copilot CLI 1.0.83."
    echo "Run 'copilot update' to check for updates."
fi
exit 0
EOF
    chmod +x "$MOCK_BIN/copilot"
}

@test "status.sh detects Codex CLI when installed" {
    mock_claude_with_plugins '[
      {"id":"context-mode@context-mode","version":"1.0.107","enabled":true},
      {"id":"claude-mem@thedotmack","version":"12.1.4","enabled":true},
      {"id":"caveman@caveman","version":"abc","enabled":true}
    ]'
    mock_rtk_alive
    mock_codex
    run bash "$STATUS_SCRIPT"
    [[ "$output" == *"Codex"*"0.131.0"*"OK"* ]]
}

@test "status.sh detects Codex when system-installed" {
    mock_claude_with_plugins '[
      {"id":"context-mode@context-mode","version":"1.0.107","enabled":true}
    ]'
    mock_rtk_alive
    # Codex is system-installed on dev machine — status.sh picks it up
    run bash "$STATUS_SCRIPT"
    # Codex should appear somewhere in the provider section
    [[ "$output" == *"Codex"* ]]
}

@test "status.sh detects Gemini CLI when installed" {
    mock_claude_with_plugins '[
      {"id":"context-mode@context-mode","version":"1.0.107","enabled":true},
      {"id":"claude-mem@thedotmack","version":"12.1.4","enabled":true},
      {"id":"caveman@caveman","version":"abc","enabled":true}
    ]'
    mock_rtk_alive
    mock_gemini
    run bash "$STATUS_SCRIPT"
    [[ "$output" == *"Gemini CLI"*"0.38.2"*"OK"* ]]
}

@test "status.sh detects Kimi Code CLI when installed" {
    mock_claude_with_plugins '[
      {"id":"context-mode@context-mode","version":"1.0.107","enabled":true},
      {"id":"claude-mem@thedotmack","version":"12.1.4","enabled":true},
      {"id":"caveman@caveman","version":"abc","enabled":true}
    ]'
    mock_rtk_alive
    mock_kimi
    run bash "$STATUS_SCRIPT"
    [[ "$output" == *"Kimi Code CLI"*"0.9.1"*"OK"* ]]
}

@test "status.sh detects opencode when installed" {
    mock_claude_with_plugins '[
      {"id":"context-mode@context-mode","version":"1.0.107","enabled":true},
      {"id":"claude-mem@thedotmack","version":"12.1.4","enabled":true},
      {"id":"caveman@caveman","version":"abc","enabled":true}
    ]'
    mock_rtk_alive
    mock_opencode
    run bash "$STATUS_SCRIPT"
    [[ "$output" == *"opencode"*"1.15.4"*"OK"* ]]
}

# ── Provider section in gain.sh ──────────────────────────────────

@test "gain.sh shows Codex in providers table" {
    mock_rtk_alive
    mock_codex
    # Codex SQLite won't exist in test HOME — shows N/A
    run bash "$GAIN_SCRIPT"
    [[ "$output" == *"Codex"*"N/A"* ]]
}

@test "gain.sh shows Gemini in providers table" {
    mock_rtk_alive
    mock_gemini
    run bash "$GAIN_SCRIPT"
    [[ "$output" == *"Gemini CLI"*"N/A"* ]]
}

@test "gain.sh shows Kimi Code CLI in providers table" {
    mock_rtk_alive
    mock_kimi
    run bash "$GAIN_SCRIPT"
    [[ "$output" == *"Kimi Code CLI"*"N/A"* ]]
}

@test "gain.sh shows opencode N/A when its DB is absent" {
    mock_rtk_alive
    mock_opencode
    # No opencode.db in the test data home → honest N/A
    OPENCODE_DATA_HOME="$BATS_TEST_TMPDIR/no-opencode" run bash "$GAIN_SCRIPT"
    [[ "$output" == *"opencode"*"N/A"* ]]
}

@test "gain.sh reads REAL opencode token telemetry from opencode.db" {
    command -v python3 >/dev/null 2>&1 || skip "python3 required to build/read the opencode DB"
    mock_rtk_alive
    mock_opencode
    local data_home="$BATS_TEST_TMPDIR/opencode-data"
    mkdir -p "$data_home"
    # Build a minimal opencode.db mirroring the real schema's token columns and
    # seed two sessions totalling 30000 tokens (12000+8000 in, 6000+4000 out).
    OPENCODE_DB="$data_home/opencode.db" python3 -c "
import sqlite3, os
db = sqlite3.connect(os.environ['OPENCODE_DB'])
db.execute('''CREATE TABLE session (
  id text PRIMARY KEY, time_created integer NOT NULL,
  tokens_input integer DEFAULT 0 NOT NULL, tokens_output integer DEFAULT 0 NOT NULL,
  tokens_reasoning integer DEFAULT 0 NOT NULL)''')
db.execute(\"INSERT INTO session VALUES ('s1', 1748000000000, 12000, 6000, 0)\")
db.execute(\"INSERT INTO session VALUES ('s2', 1748000000000, 8000, 4000, 0)\")
db.commit()
"
    OPENCODE_DATA_HOME="$data_home" run bash "$GAIN_SCRIPT"
    [ "$status" -eq 0 ]
    # 30000 tokens → rendered as 30.0K, with the real-session note.
    [[ "$output" == *"opencode"*"30.0K"* ]]
    [[ "$output" == *"2 opencode sessions (real token cols)"* ]]
}

# ── Copilot CLI ───────────────────────────────────────────────────

@test "status.sh detects Copilot CLI and strips its trailing full stop" {
    mock_claude_with_plugins '[
      {"id":"context-mode@context-mode","version":"1.0.107","enabled":true}
    ]'
    mock_rtk_alive
    mock_copilot
    run bash "$STATUS_SCRIPT"
    # "1.0.83." would never compare equal to a registry version — the parser has
    # to drop the trailing punctuation.
    [[ "$output" == *"Copilot CLI"*"1.0.83"*"OK"* ]]
    [[ "$output" != *"1.0.83."* ]]
}

@test "status.sh names the Copilot telemetry source" {
    mock_claude_with_plugins '[]'
    mock_rtk_alive
    mock_copilot
    run bash "$STATUS_SCRIPT"
    [[ "$output" == *"session-store.db"* ]]
}

@test "gain.sh shows Copilot N/A when its session store is absent" {
    mock_rtk_alive
    mock_copilot
    COPILOT_HOME="$BATS_TEST_TMPDIR/no-copilot" run bash "$GAIN_SCRIPT"
    [[ "$output" == *"Copilot CLI"*"N/A"* ]]
}

@test "gain.sh reads REAL Copilot token telemetry and AI credits from session-store.db" {
    command -v python3 >/dev/null 2>&1 || skip "python3 required to build/read the Copilot DB"
    mock_rtk_alive
    mock_copilot
    local copilot_home="$BATS_TEST_TMPDIR/copilot-home"
    mkdir -p "$copilot_home"
    # Mirror the real schema's usage columns: two calls in one session totalling
    # 30000 tokens (20000 in + 9000 out + 1000 reasoning) and 1.5 AI credits.
    COPILOT_DB="$copilot_home/session-store.db" python3 - <<'PYEOF'
import sqlite3, os
db = sqlite3.connect(os.environ['COPILOT_DB'])
db.execute(
    "CREATE TABLE assistant_usage_events ("
    "id integer PRIMARY KEY AUTOINCREMENT, session_id text NOT NULL, model text NOT NULL,"
    "input_tokens integer, output_tokens integer, cache_read_tokens integer,"
    "cache_write_tokens integer, reasoning_tokens integer, total_nano_aiu integer,"
    "created_at text)"
)
ins = ("INSERT INTO assistant_usage_events (session_id, model, input_tokens, output_tokens,"
       " cache_read_tokens, cache_write_tokens, reasoning_tokens, total_nano_aiu, created_at)"
       " VALUES (?,?,?,?,?,?,?,?,?)")
db.execute(ins, ('s1', 'm', 12000, 5000, 0, 0, 1000, 1000000000, '2026-09-01T10:00:00.000Z'))
db.execute(ins, ('s1', 'm', 8000, 4000, 0, 0, 0, 500000000, '2026-09-02T10:00:00.000Z'))
db.commit()
PYEOF
    COPILOT_HOME="$copilot_home" run bash "$GAIN_SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Copilot CLI"*"30.0K"* ]]
    [[ "$output" == *"1 Copilot sessions (real assistant_usage_events)"* ]]
    # AI credits are the unit GitHub actually bills — tokens alone understate it.
    [[ "$output" == *"1.50 AI credits billed"* ]]
}
