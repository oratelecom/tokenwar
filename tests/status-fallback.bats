#!/usr/bin/env bats
# Tests for status.sh's fallback path (lib/plugins.sh) — when `claude plugin list
# --json` yields nothing, the plugin list is derived from on-disk config:
# installed_plugins.json for installed + settings.json/settings.local.json →
# enabledPlugins for the enabled bit. Regression guard for #8/#10: an explicitly
# disabled plugin must NOT report OK (the hardcoded-`enabled:true` version did).

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../scripts/status.sh"
    [ -x "$SCRIPT" ] || skip "status.sh not executable"

    MOCK_BIN="$(mktemp -d)"
    export ORIG_PATH="$PATH"
    export PATH="$MOCK_BIN:$PATH"

    # Injectable fake ~/.claude for the fallback to read.
    export CLAUDE_CONFIG_DIR="$(mktemp -d)"
    mkdir -p "$CLAUDE_CONFIG_DIR/plugins"

    # claude CLI present but returns NOTHING for `plugin list --json` → forces the
    # fallback while proving we distinguish "empty CLI" from "no CLI".
    cat > "$MOCK_BIN/claude" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "$MOCK_BIN/claude"

    # rtk + pxpipe healthy so only plugin state varies.
    cat > "$MOCK_BIN/rtk" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == "gain" ]] && echo "Tokens saved: 1M"
[[ "$1" == "--version" ]] && echo "rtk 0.30.1"
exit 0
EOF
    chmod +x "$MOCK_BIN/rtk"
    cat > "$MOCK_BIN/pxpipe" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == "--version" ]] && echo "0.10.0"
exit 0
EOF
    chmod +x "$MOCK_BIN/pxpipe"
}

teardown() {
    rm -rf "$MOCK_BIN" "$CLAUDE_CONFIG_DIR"
    export PATH="$ORIG_PATH"
}

write_installed()      { printf '%s\n' "$1" > "$CLAUDE_CONFIG_DIR/plugins/installed_plugins.json"; }
write_settings()       { printf '%s\n' "$1" > "$CLAUDE_CONFIG_DIR/settings.json"; }
write_settings_local() { printf '%s\n' "$1" > "$CLAUDE_CONFIG_DIR/settings.local.json"; }

@test "fallback: an explicitly disabled plugin reports installed-disabled (not OK)" {
    write_installed '{"plugins":{"context-mode@context-mode":[{"version":"1.0.107"}]}}'
    write_settings  '{"enabledPlugins":{"context-mode@context-mode":false}}'
    run bash "$SCRIPT"
    [[ "$output" == *"context-mode"*"installed-disabled"* ]]
}

@test "fallback: an explicitly enabled plugin reports OK" {
    write_installed '{"plugins":{"context-mode@context-mode":[{"version":"1.0.107"}]}}'
    write_settings  '{"enabledPlugins":{"context-mode@context-mode":true}}'
    run bash "$SCRIPT"
    [[ "$output" == *"context-mode"*"1.0.107"*"OK"* ]]
}

@test "fallback: installed but absent from enabledPlugins defaults to enabled (OK)" {
    write_installed '{"plugins":{"context-mode@context-mode":[{"version":"1.0.107"}]}}'
    write_settings  '{"enabledPlugins":{}}'
    run bash "$SCRIPT"
    [[ "$output" == *"context-mode"*"OK"* ]]
}

@test "fallback: a plugin not in installed_plugins reports not-installed" {
    write_installed '{"plugins":{}}'
    write_settings  '{"enabledPlugins":{}}'
    run bash "$SCRIPT"
    [[ "$output" == *"context-mode"*"not-installed"* ]]
}

@test "fallback: malformed installed_plugins.json degrades to not-installed, no crash" {
    write_installed 'this is not json'
    write_settings  '{"enabledPlugins":{}}'
    run bash "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"context-mode"*"not-installed"* ]]
}

@test "fallback: enabled only in settings.local.json still reports OK (OR-merge)" {
    # Regression: Claude Code merges settings.json + settings.local.json at
    # runtime, so a plugin enabled solely in the local file must NOT read disabled.
    write_installed       '{"plugins":{"context-mode@context-mode":[{"version":"1.0.107"}]}}'
    write_settings        '{"enabledPlugins":{"context-mode@context-mode":false}}'
    write_settings_local  '{"enabledPlugins":{"context-mode@context-mode":true}}'
    run bash "$SCRIPT"
    [[ "$output" == *"context-mode"*"OK"* ]]
    [[ "$output" != *"context-mode"*"installed-disabled"* ]]
}
