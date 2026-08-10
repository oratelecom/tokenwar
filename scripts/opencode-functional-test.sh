#!/usr/bin/env bash
# Functional RTK/OpenCode proof for tokenwar CI and local diagnosis.

set -euo pipefail

readonly RTK_BIN="${RTK_BIN:-rtk}"
readonly OPENCODE_BIN="${OPENCODE_BIN:-opencode}"
readonly TMP_PARENT="${TMPDIR:-/tmp}"
readonly TMP_TEMPLATE="${TMP_PARENT}/tokenwar-opencode-functional.XXXXXX"
readonly OPENCODE_PLUGIN_REL=".config/opencode/plugins/rtk.ts"
readonly REWRITE_INPUT="git status"
readonly REWRITE_EXPECTED="rtk git status"
readonly PLUGIN_PROBE="rtk rewrite"

TEST_HOME=""

say_ok() { printf '[ok] %s\n' "$*"; }
say_fail() { printf '[fail] %s\n' "$*" >&2; }

cleanup() {
    if [[ -n "$TEST_HOME" && -d "$TEST_HOME" ]]; then
        find "$TEST_HOME" -depth -mindepth 1 -delete 2>/dev/null || true
        rmdir "$TEST_HOME" 2>/dev/null || true
    fi
}
trap cleanup EXIT

require_bin() {
    local bin="$1"
    if ! command -v "$bin" >/dev/null 2>&1; then
        say_fail "$bin not found on PATH"
        exit 127
    fi
}

require_bin "$RTK_BIN"
require_bin "$OPENCODE_BIN"

TEST_HOME="$(mktemp -d "$TMP_TEMPLATE")"
readonly TEST_HOME
readonly PLUGIN_PATH="${TEST_HOME}/${OPENCODE_PLUGIN_REL}"
readonly PLUGIN_URI="file://${PLUGIN_PATH}"
readonly INIT_LOG="${TEST_HOME}/rtk-init.log"

printf '[info] temp HOME: %s\n' "$TEST_HOME"
printf '[info] rtk: %s\n' "$("$RTK_BIN" --version 2>/dev/null || printf 'version unavailable')"
printf '[info] opencode: %s\n' "$("$OPENCODE_BIN" --version 2>/dev/null || printf 'version unavailable')"

if ! HOME="$TEST_HOME" "$RTK_BIN" init -g --opencode >"$INIT_LOG" 2>&1; then
    say_fail "rtk init -g --opencode failed"
    sed -n '1,160p' "$INIT_LOG" >&2
    exit 1
fi
say_ok "rtk init -g --opencode"

if [[ ! -s "$PLUGIN_PATH" ]]; then
    say_fail "RTK OpenCode plugin not written at $PLUGIN_PATH"
    exit 1
fi
say_ok "plugin file exists: $PLUGIN_PATH"

if ! grep -q "$PLUGIN_PROBE" "$PLUGIN_PATH"; then
    say_fail "plugin file does not delegate to '$PLUGIN_PROBE'"
    exit 1
fi
say_ok "plugin delegates bash rewrites to rtk"

config_output="$(HOME="$TEST_HOME" "$OPENCODE_BIN" debug config 2>&1)"
printf '%s\n' "$config_output" | sed -n '/"plugin"/,/"plugin_origins"/p'

if [[ "$config_output" != *"$PLUGIN_URI"* ]]; then
    say_fail "opencode resolved config does not reference $PLUGIN_URI"
    exit 1
fi
say_ok "opencode config references RTK plugin"

rewrite_output="$("$RTK_BIN" rewrite "$REWRITE_INPUT" 2>/dev/null || true)"
rewrite_output="${rewrite_output//$'\r'/}"
rewrite_output="${rewrite_output%%$'\n'*}"

if [[ "$rewrite_output" != "$REWRITE_EXPECTED" ]]; then
    say_fail "unexpected rewrite: '$rewrite_output' (expected '$REWRITE_EXPECTED')"
    exit 1
fi
say_ok "rtk rewrite: $REWRITE_INPUT -> $REWRITE_EXPECTED"

say_ok "functional RTK/OpenCode proof complete"
