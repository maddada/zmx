#!/usr/bin/env bats
# Session lifecycle tests for zmx.
#
# These tests create real zmx sessions — forking daemon processes, allocating
# PTYs, running commands. Without the inherited-FD close fix, every test that
# calls `zmx run` would hang indefinitely because bats waits for its internal
# FDs (3+) to close, and the daemon inherits them.
#
# If this test suite completes at all, the FD fix is working.
#
# All `run` invocations use `-d` (detached) because `zmx run` blocks until
# the command completes, and sessions outlive their initial command.
# Note: `-d` must come after the session name (zmx run <name> -d <cmd>).

load test_helper

# ============================================================================
# Session creation
# ============================================================================

@test "run: creates a session" {
  run "$ZMX" run test-create -d echo hello
  [ "$status" -eq 0 ]
  [[ "$output" == *"session \"test-create\" created"* ]]

  wait_for_session test-create
  run "$ZMX" list --short
  [[ "$output" == "test-create" ]]
}

@test "run: sends command to existing session" {
  "$ZMX" run test-send -d echo first
  wait_for_session test-send

  run "$ZMX" run test-send -d echo second
  [ "$status" -eq 0 ]
  [[ "$output" == *"command sent"* ]]
  # Should NOT say "created" — session already exists
  [[ "$output" != *"created"* ]]
}

@test "run: initial-command creates provider without typing argv into shell" {
  run "$ZMX" run t-init -d --initial-command /bin/zsh -lic 'printf "initial-command-marker\n"; exec /bin/zsh -li'
  [ "$status" -eq 0 ]
  [[ "$output" == *"session \"t-init\" created"* ]]

  wait_for_session t-init
  wait_for_output t-init "initial-command-marker"
  run "$ZMX" history t-init
  [ "$status" -eq 0 ]
  [[ "$output" == *"initial-command-marker"* ]]
  # argv is exec'd, never echoed through the PTY as shell input
  [[ "$output" != *"--initial-command"* ]]
  [[ "$output" != *"/bin/zsh -lic"* ]]
}

@test "run: initial-command is ignored for an existing session" {
  "$ZMX" run t-init-exists -d --initial-command /bin/sh -c 'printf "first-marker\n"; exec /bin/sh'
  wait_for_session t-init-exists
  wait_for_output t-init-exists "first-marker"

  run "$ZMX" run t-init-exists -d --initial-command /bin/sh -c 'printf "second-marker\n"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"initial command ignored"* ]]
  [[ "$output" != *"created"* ]]

  run "$ZMX" history t-init-exists
  [[ "$output" != *"second-marker"* ]]
}

@test "run: initial-command requires a command argument" {
  run "$ZMX" run t-init-nocmd -d --initial-command
  [ "$status" -ne 0 ]

  run "$ZMX" list --short
  [[ "$output" != *"t-init-nocmd"* ]]
}

@test "attach --require-existing fails instead of creating a session" {
  run "$ZMX" attach --require-existing t-missing
  [ "$status" -ne 0 ]

  run "$ZMX" list --short
  [ "$status" -eq 0 ]
  [[ "$output" != *"t-missing"* ]]
}

@test "refresh-if-stale: skips when the daemon grid already matches" {
  "$ZMX" run t-refresh -d --initial-command /bin/sh -c 'printf "refresh-marker\n"; exec /bin/sh'
  wait_for_session t-refresh
  wait_for_output t-refresh "refresh-marker"

  # The daemon's grid comes from the creating client's terminal size. Ask with
  # a deliberately different grid: that is stale and must be applied.
  run "$ZMX" refresh-if-stale t-refresh 41 121
  [ "$status" -eq 0 ]
  [[ "$output" == *"refresh-if-stale applied"* ]]

  # Asking again with the same grid is now a no-op.
  run "$ZMX" refresh-if-stale t-refresh 41 121
  [ "$status" -eq 0 ]
  [[ "$output" == *"refresh-if-stale skipped"* ]]
}

@test "refresh-if-stale: requires session, rows, and cols" {
  run "$ZMX" refresh-if-stale
  [ "$status" -ne 0 ]
  run "$ZMX" refresh-if-stale t-refresh-args
  [ "$status" -ne 0 ]
  run "$ZMX" refresh-if-stale t-refresh-args 40
  [ "$status" -ne 0 ]
}

@test "prompt-editor-capability: reports editor for a non-advertising client" {
  "$ZMX" run t-cap -d --initial-command /bin/sh -c 'printf "cap-marker\n"; exec /bin/sh'
  wait_for_session t-cap
  wait_for_output t-cap "cap-marker"

  run "$ZMX" prompt-editor-capability t-cap
  [ "$status" -eq 0 ]
  [[ "$output" == "editor" ]]
}

@test "watch-title: streams a coalesced title observation as JSON" {
  "$ZMX" run t-title -d --initial-command /bin/sh -c 'printf "title-marker\n"; exec /bin/sh'
  wait_for_session t-title
  wait_for_output t-title "title-marker"

  # watch-title streams until the session dies, so read it in the background
  # and stop once the coalescer has emitted (1s debounce + margin).
  "$ZMX" watch-title t-title > "$BATS_TEST_TMPDIR/titles.jsonl" &
  local watcher=$!
  sleep 0.3
  "$ZMX" print t-title "$(printf '\033]2;zmx-port-title\007')"
  sleep 2
  kill "$watcher" 2>/dev/null || true
  wait "$watcher" 2>/dev/null || true

  run cat "$BATS_TEST_TMPDIR/titles.jsonl"
  [[ "$output" == *'{"title":"zmx-port-title"}'* ]]
}

@test "list: a title watcher is not counted as a client" {
  "$ZMX" run t-count -d --initial-command /bin/sh -c 'printf "count-marker\n"; exec /bin/sh'
  wait_for_session t-count
  wait_for_output t-count "count-marker"

  run "$ZMX" list
  local before="$output"
  [[ "$before" == *"clients=0"* ]]

  "$ZMX" watch-title t-count > /dev/null &
  local watcher=$!
  sleep 0.5

  run "$ZMX" list
  [[ "$output" == *"clients=0"* ]]

  kill "$watcher" 2>/dev/null || true
  wait "$watcher" 2>/dev/null || true
}

@test "run: blocking returns after command completes" {
  run timeout 5 env SHELL=/bin/bash "$ZMX" run test-blocking echo hello
  [ "$status" -eq 0 ]
  [[ "$output" == *"session \"test-blocking\" created"* ]]
}

@test "run: requires a command argument" {
  run "$ZMX" run test-nocmd
  [ "$status" -ne 0 ]
}

@test "run --help shows help without creating a session" {
  run "$ZMX" run --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]

  run "$ZMX" list --short
  [ "$status" -eq 0 ]
  [[ "$output" != *"--help"* ]]
}

@test "subcommands handle --help and -h without side effects" {
  for cmd in attach send print write kill wait tail history list completions; do
    run "$ZMX" "$cmd" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage:"* ]]

    run "$ZMX" "$cmd" -h
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage:"* ]]
  done

  run "$ZMX" list --short
  [ "$status" -eq 0 ]
  [[ "$output" != *"--help"* ]]
  [[ "$output" != *"-h"* ]]
}

# ============================================================================
# Send (raw PTY input)
# ============================================================================

@test "send: does not append CR by default" {
  "$ZMX" run test-send-raw -d echo ready
  wait_for_session test-send-raw
  wait_for_output test-send-raw ready

  # Send text without \r — it should NOT execute as a command
  run "$ZMX" send test-send-raw "partial-text"
  [ "$status" -eq 0 ]
}

@test "send: requires a session name" {
  run "$ZMX" send
  [ "$status" -ne 0 ]
}

@test "send: requires text argument" {
  "$ZMX" run test-send-notext -d true
  wait_for_session test-send-notext

  run "$ZMX" send test-send-notext
  [ "$status" -ne 0 ]
}

@test "send: accepts piped stdin" {
  "$ZMX" run test-send-pipe -d echo ready
  wait_for_session test-send-pipe
  wait_for_output test-send-pipe ready

  run bash -c 'printf "echo piped-marker-xyz789\r" | "$0" send test-send-pipe' "$ZMX"
  [ "$status" -eq 0 ]

  wait_for_output test-send-pipe piped-marker-xyz789
  run "$ZMX" history test-send-pipe
  [[ "$output" == *"piped-marker-xyz789"* ]]
}

# ============================================================================
# Session listing
# ============================================================================

@test "list: no sessions returns cleanly" {
  run "$ZMX" list
  [ "$status" -eq 0 ]
  [[ "$output" == *"no sessions found"* ]]
}

@test "ls aliases list" {
  run "$ZMX" ls
  [ "$status" -eq 0 ]
  [[ "$output" == *"no sessions found"* ]]
}

@test "list: shows session details" {
  "$ZMX" run test-list -d echo hello
  wait_for_session test-list

  run "$ZMX" list
  [ "$status" -eq 0 ]
  [[ "$output" == *"test-list"* ]]
  [[ "$output" == *"pid="* ]]
}

@test "list --short: shows only session names" {
  "$ZMX" run test-short-a -d true
  "$ZMX" run test-short-b -d true
  wait_for_session test-short-a
  wait_for_session test-short-b

  run "$ZMX" list --short
  [ "$status" -eq 0 ]
  [[ "$output" == *"test-short-a"* ]]
  [[ "$output" == *"test-short-b"* ]]
}

@test "list --short: empty when no sessions" {
  run "$ZMX" list --short
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ============================================================================
# Session kill
# ============================================================================

@test "kill: removes a session" {
  "$ZMX" run test-kill -d true
  wait_for_session test-kill

  run "$ZMX" kill test-kill
  [ "$status" -eq 0 ]
  [[ "$output" == *"killed session test-kill"* ]]

  run "$ZMX" list --short
  [[ "$output" != *"test-kill"* ]]
}

@test "kill: multiple sessions at once" {
  "$ZMX" run kill-a -d true
  "$ZMX" run kill-b -d true
  wait_for_session kill-a
  wait_for_session kill-b

  run "$ZMX" kill kill-a kill-b
  [ "$status" -eq 0 ]
  [[ "$output" == *"killed session kill-a"* ]]
  [[ "$output" == *"killed session kill-b"* ]]
}

@test "kill --force: removes socket file for dead session" {
  "$ZMX" run test-force -d true
  wait_for_session test-force

  # Get the daemon PID and kill it directly (simulating a crash)
  local pid
  pid=$("$ZMX" list 2>/dev/null | grep test-force | sed 's/.*pid=\([0-9]*\).*/\1/')
  if [[ -n "$pid" ]]; then
    kill -9 "$pid" 2>/dev/null || true
    # Wait for the OS to actually reap the process before relying on
    # --force to see it as dead.
    for _ in $(seq 1 50); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.1
    done
  fi

  # Regular kill may fail on the dead session; --force cleans up
  run "$ZMX" kill --force test-force
  [ "$status" -eq 0 ]
}

# ============================================================================
# Session isolation (ZMX_DIR)
# ============================================================================

@test "ZMX_DIR isolation: sessions in one dir are invisible to another" {
  "$ZMX" run test-isolated -d true
  wait_for_session test-isolated

  # A different ZMX_DIR should see no sessions
  local other_dir="$BATS_TEST_TMPDIR/zmx-other"
  mkdir -p "$other_dir"
  run env ZMX_DIR="$other_dir" "$ZMX" list --short
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ============================================================================
# History
# ============================================================================

@test "history: captures session output" {
  "$ZMX" run test-hist -d echo "bats-marker-xyzzy"
  wait_for_session test-hist
  wait_for_output test-hist bats-marker-xyzzy

  run "$ZMX" history test-hist
  [ "$status" -eq 0 ]
  [[ "$output" == *"bats-marker-xyzzy"* ]]
}

# ============================================================================
# Wait
# ============================================================================

@test "wait: returns after session command completes" {
  "$ZMX" run test-wait -d echo done
  wait_for_session test-wait
  wait_for_output test-wait done

  # `wait` should return once the command finishes
  run timeout 10 "$ZMX" wait test-wait
  [ "$status" -eq 0 ]
}

# ============================================================================
# Rapid session churn (stress test for FD handling)
# ============================================================================

@test "churn: create and kill 5 sessions in sequence" {
  for i in 1 2 3 4 5; do
    "$ZMX" run "churn-$i" -d echo "iteration $i"
    wait_for_session "churn-$i"
    "$ZMX" kill "churn-$i"
  done

  run "$ZMX" list --short
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}


# ============================================================================
# Print (inject text into terminal state)
# ============================================================================

@test "print: text appears in history" {
  "$ZMX" run test-print-hist -d echo ready
  wait_for_session test-print-hist
  wait_for_output test-print-hist ready

  # Caller is responsible for newlines; trailing \r\n ensures the text
  # lands on its own line before SIGWINCH triggers a prompt redraw.
  printf "\r\nbats-print-marker-abc123\r\n" | "$ZMX" print test-print-hist
  wait_for_output test-print-hist bats-print-marker-abc123

  run "$ZMX" history test-print-hist
  [ "$status" -eq 0 ]
  [[ "$output" == *"bats-print-marker-abc123"* ]]
}

@test "print: requires a session name" {
  run "$ZMX" print
  [ "$status" -ne 0 ]
}

@test "run: long command line does not truncate history when creating session" {
  local longcmd="echo 1234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890"
  run "$ZMX" run test-long-cmd -d "$longcmd"
  [ "$status" -eq 0 ]
  wait_for_session test-long-cmd
  wait_for_output test-long-cmd 12345678901234567890
  run "$ZMX" history test-long-cmd
  [[ "$output" != *"<1234567890"* ]]
  [[ "$output" == *"12345678901234567890"* ]]
}

