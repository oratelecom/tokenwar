#!/usr/bin/env bats
@test "sanitized snapshots and comparisons preserve uncertainty" {
  run node --test "$BATS_TEST_DIRNAME/history.test.mjs"
  [ "$status" -eq 0 ]
}
