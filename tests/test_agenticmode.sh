#!/bin/bash

set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_root=$(mktemp -d "${TMPDIR:-/tmp}/agenticmode-test.XXXXXX")
mock_bin="$test_root/bin"
state_dir="$test_root/state"
pmset_state="$test_root/pmset-state"
pmset_log="$test_root/pmset.log"
sudo_log="$test_root/sudo.log"
watchdog_log="$test_root/watchdog.log"
battery_percent_file="$test_root/battery-percent"
power_source_file="$test_root/power-source"
pmset_fail_value_file="$test_root/pmset-fail-value"
pmset_fail_count_file="$test_root/pmset-fail-count"
codex_home="$test_root/codex"
config_file="$test_root/missing-config"
controller_pid=""
child_pid=""
agent_pids=""

cleanup() {
  if [ -n "$controller_pid" ]; then
    kill -TERM "$controller_pid" 2>/dev/null || true
    wait "$controller_pid" 2>/dev/null || true
  fi
  if [ -n "$child_pid" ]; then
    kill -TERM "$child_pid" 2>/dev/null || true
    wait "$child_pid" 2>/dev/null || true
  fi
  for agent_pid in $agent_pids; do
    kill -TERM "$agent_pid" 2>/dev/null || true
    wait "$agent_pid" 2>/dev/null || true
  done
  rm -rf "$test_root"
}
trap cleanup EXIT INT TERM

mkdir -p "$mock_bin" "$codex_home/sessions/2026/08/11"
printf '0\n' > "$pmset_state"
printf '100\n' > "$battery_percent_file"
printf 'AC Power\n' > "$power_source_file"
printf 'none\n' > "$pmset_fail_value_file"
printf '0\n' > "$pmset_fail_count_file"
: > "$pmset_log"
: > "$sudo_log"
: > "$watchdog_log"

cat > "$mock_bin/pmset" <<'MOCK'
#!/bin/bash
set -u
printf '%s\n' "$*" >> "$AGENTICMODE_TEST_PMSET_LOG"
if [ "${1:-}" = "-g" ] && [ "${2:-}" = "batt" ]; then
  printf "Now drawing from '%s'\n" "$(cat "$AGENTICMODE_TEST_POWER_SOURCE")"
  printf ' -InternalBattery-0 %s%%; discharging\n' "$(cat "$AGENTICMODE_TEST_BATTERY_PERCENT")"
elif [ "${1:-}" = "-g" ]; then
  printf ' SleepDisabled %s\n' "$(cat "$AGENTICMODE_TEST_PMSET_STATE")"
elif [ "${1:-}" = "-a" ] && [ "${2:-}" = "disablesleep" ]; then
  fail_value=$(cat "$AGENTICMODE_TEST_PMSET_FAIL_VALUE")
  fail_count=$(cat "$AGENTICMODE_TEST_PMSET_FAIL_COUNT")
  if [ "$3" = "$fail_value" ] && [ "$fail_count" -gt 0 ]; then
    printf '%s\n' "$((fail_count - 1))" > "$AGENTICMODE_TEST_PMSET_FAIL_COUNT"
    exit 1
  fi
  printf '%s\n' "$3" > "$AGENTICMODE_TEST_PMSET_STATE"
else
  exit 1
fi
MOCK

cat > "$mock_bin/sudo" <<'MOCK'
#!/bin/bash
printf '%s\n' "$*" >> "$AGENTICMODE_TEST_SUDO_LOG"
[ "${1:-}" != "-v" ] || exit 0
[ -z "${AGENTICMODE_TEST_SUDO_EXEC_DELAY:-}" ] || /bin/sleep "$AGENTICMODE_TEST_SUDO_EXEC_DELAY"
exec "$@"
MOCK

chmod 755 "$mock_bin/pmset" "$mock_bin/sudo"

export AGENTICMODE_TESTING=1
export AGENTICMODE_PMSET_BIN="$mock_bin/pmset"
export AGENTICMODE_SUDO_BIN="$mock_bin/sudo"
export AGENTICMODE_WATCHDOG_BIN="$repo_dir/libexec/agenticmode-watchdog"
export AGENTICMODE_STATE_DIR="$state_dir"
export AGENTICMODE_TEST_PMSET_STATE="$pmset_state"
export AGENTICMODE_TEST_PMSET_LOG="$pmset_log"
export AGENTICMODE_TEST_SUDO_LOG="$sudo_log"
export AGENTICMODE_TEST_WATCHDOG_LOG="$watchdog_log"
export AGENTICMODE_TEST_BATTERY_PERCENT="$battery_percent_file"
export AGENTICMODE_TEST_POWER_SOURCE="$power_source_file"
export AGENTICMODE_TEST_PMSET_FAIL_VALUE="$pmset_fail_value_file"
export AGENTICMODE_TEST_PMSET_FAIL_COUNT="$pmset_fail_count_file"
export AGENTICMODE_CODEX_HOME="$codex_home"
export AGENTICMODE_CONFIG="$config_file"
export AGENTICMODE_POLL_SECONDS=1

assert_equals() {
  if [ "$1" != "$2" ]; then
    printf 'Expected "%s", got "%s"\n' "$1" "$2" >&2
    exit 1
  fi
}

assert_contains() {
  pattern="$1"
  file="$2"
  if ! grep -Fq -- "$pattern" "$file"; then
    printf 'Expected %s to contain: %s\n' "$file" "$pattern" >&2
    sed -n '1,200p' "$file" >&2
    exit 1
  fi
}

assert_not_contains() {
  pattern="$1"
  file="$2"
  if grep -Fq -- "$pattern" "$file"; then
    printf 'Expected %s not to contain: %s\n' "$file" "$pattern" >&2
    sed -n '1,200p' "$file" >&2
    exit 1
  fi
}

assert_occurrences() {
  expected="$1"
  pattern="$2"
  file="$3"
  actual=$(grep -Fc -- "$pattern" "$file" || true)
  assert_equals "$expected" "$actual"
}

wait_for_contains() {
  pattern="$1"
  file="$2"
  attempts=0
  while [ "$attempts" -lt 80 ]; do
    grep -Fq -- "$pattern" "$file" 2>/dev/null && return 0
    /bin/sleep 0.1
    attempts=$((attempts + 1))
  done
  assert_contains "$pattern" "$file"
}

wait_for_value() {
  expected="$1"
  file="$2"
  attempts=0
  while [ "$attempts" -lt 80 ]; do
    actual=$(cat "$file" 2>/dev/null || true)
    [ "$actual" = "$expected" ] && return 0
    /bin/sleep 0.1
    attempts=$((attempts + 1))
  done
  printf 'Timed out waiting for %s in %s\n' "$expected" "$file" >&2
  dump_logs
  exit 1
}

wait_for_exit() {
  pid="$1"
  attempts=0
  while kill -0 "$pid" 2>/dev/null && [ "$attempts" -lt 120 ]; do
    process_state=$(/bin/ps -p "$pid" -o state= 2>/dev/null | /usr/bin/awk '{print substr($1,1,1)}')
    [ -n "$process_state" ] && [ "$process_state" != "Z" ] || return 0
    /bin/sleep 0.1
    attempts=$((attempts + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    printf 'Timed out waiting for PID %s to exit\n' "$pid" >&2
    dump_logs
    exit 1
  fi
}

dump_logs() {
  for log_file in "$test_root"/*.log; do
    [ -f "$log_file" ] || continue
    printf '%s\n' "Contents of $log_file:" >&2
    sed -n '1,200p' "$log_file" >&2
  done
}

clear_codex_fixtures() {
  find "$codex_home/sessions" -type f -name '*.jsonl' -delete
}

printf 'Test: syntax and version\n'
/bin/bash -n "$repo_dir/bin/agenticmode" "$repo_dir/libexec/agenticmode-watchdog" "$repo_dir/install.sh" "$repo_dir/uninstall.sh" "$repo_dir/scripts/package-release.sh"
assert_equals "agenticmode 1.3.0" "$("$repo_dir/bin/agenticmode" --version)"
"$repo_dir/bin/agenticmode" --help > "$test_root/help-command.log"
assert_contains "agenticmode update" "$test_root/help-command.log"

printf 'Test: signal cleanup restores a normal baseline\n'
"$repo_dir/bin/agenticmode" > "$test_root/interrupt.log" 2>&1 &
controller_pid=$!
wait_for_value 1 "$pmset_state"
kill -TERM "$controller_pid"
wait_for_exit "$controller_pid"
wait "$controller_pid" 2>/dev/null || true
controller_pid=""
wait_for_value 0 "$pmset_state"

printf 'Test: Ctrl+C signal path restores sleep\n'
set +e
"$repo_dir/bin/agenticmode" run -- /bin/sh -c 'kill -INT "$PPID"' > "$test_root/ctrl-c.log" 2>&1
interrupt_status=$?
set -e
assert_equals 130 "$interrupt_status"
wait_for_value 0 "$pmset_state"

printf 'Test: cleanup preserves an existing SleepDisabled baseline\n'
printf '1\n' > "$pmset_state"
"$repo_dir/bin/agenticmode" > "$test_root/baseline.log" 2>&1 &
controller_pid=$!
wait_for_value 1 "$pmset_state"
kill -TERM "$controller_pid"
wait_for_exit "$controller_pid"
wait "$controller_pid" 2>/dev/null || true
controller_pid=""
wait_for_value 1 "$pmset_state"
"$repo_dir/bin/agenticmode" off > "$test_root/baseline-off.log" 2>&1
wait_for_value 0 "$pmset_state"

printf 'Test: watchdog restores sleep after controller SIGKILL\n'
"$repo_dir/bin/agenticmode" > "$test_root/sigkill.log" 2>&1 &
controller_pid=$!
wait_for_value 1 "$pmset_state"
kill -KILL "$controller_pid"
wait "$controller_pid" 2>/dev/null || true
controller_pid=""
wait_for_value 0 "$pmset_state"
"$repo_dir/bin/agenticmode" off > "$test_root/sigkill-off.log" 2>&1

printf 'Test: immediate off drains an orphaned watchdog\n'
printf '1\n' > "$pmset_state"
"$repo_dir/bin/agenticmode" > "$test_root/orphan-off-controller.log" 2>&1 &
controller_pid=$!
wait_for_contains "System sleep is disabled" "$test_root/orphan-off-controller.log"
kill -KILL "$controller_pid"
wait "$controller_pid" 2>/dev/null || true
controller_pid=""
"$repo_dir/bin/agenticmode" off > "$test_root/orphan-off.log" 2>&1
wait_for_value 0 "$pmset_state"
/bin/sleep 3
assert_equals 0 "$(cat "$pmset_state")"

printf 'Test: immediate restart drains an orphaned watchdog first\n'
"$repo_dir/bin/agenticmode" > "$test_root/orphan-restart-old.log" 2>&1 &
controller_pid=$!
wait_for_contains "System sleep is disabled" "$test_root/orphan-restart-old.log"
kill -KILL "$controller_pid"
wait "$controller_pid" 2>/dev/null || true
controller_pid=""
"$repo_dir/bin/agenticmode" > "$test_root/orphan-restart-new.log" 2>&1 &
controller_pid=$!
wait_for_contains "System sleep is disabled" "$test_root/orphan-restart-new.log"
kill -TERM "$controller_pid"
wait_for_exit "$controller_pid"
wait "$controller_pid" 2>/dev/null || true
controller_pid=""
wait_for_value 0 "$pmset_state"

printf 'Test: off is safe during the watchdog registration gap\n'
: > "$pmset_log"
registration_ready="$test_root/registration-off.ready"
env AGENTICMODE_TEST_SUDO_EXEC_DELAY=8 \
  AGENTICMODE_TEST_WATCHDOG_REGISTRATION_DELAY=10 \
  AGENTICMODE_TEST_WATCHDOG_SPAWNED_FILE="$registration_ready" \
  "$repo_dir/bin/agenticmode" > "$test_root/registration-off-controller.log" 2>&1 &
controller_pid=$!
attempts=0
while [ ! -e "$registration_ready" ] && [ "$attempts" -lt 80 ]; do
  /bin/sleep 0.1
  attempts=$((attempts + 1))
done
[ -e "$registration_ready" ] || { printf 'Watchdog spawn hook was not reached\n' >&2; exit 1; }
kill -KILL "$controller_pid"
wait "$controller_pid" 2>/dev/null || true
controller_pid=""
"$repo_dir/bin/agenticmode" off > "$test_root/registration-off.log" 2>&1
/bin/sleep 4
assert_equals 0 "$(cat "$pmset_state")"
if grep -Fq -- '-a disablesleep 1' "$pmset_log"; then
  printf 'A delayed stopped watchdog enabled the override\n' >&2
  exit 1
fi

printf 'Test: restart is safe during the watchdog registration gap\n'
registration_ready="$test_root/registration-restart.ready"
env AGENTICMODE_TEST_SUDO_EXEC_DELAY=8 \
  AGENTICMODE_TEST_WATCHDOG_REGISTRATION_DELAY=10 \
  AGENTICMODE_TEST_WATCHDOG_SPAWNED_FILE="$registration_ready" \
  "$repo_dir/bin/agenticmode" > "$test_root/registration-restart-old.log" 2>&1 &
controller_pid=$!
attempts=0
while [ ! -e "$registration_ready" ] && [ "$attempts" -lt 80 ]; do
  /bin/sleep 0.1
  attempts=$((attempts + 1))
done
[ -e "$registration_ready" ] || { printf 'Watchdog restart spawn hook was not reached\n' >&2; exit 1; }
kill -KILL "$controller_pid"
wait "$controller_pid" 2>/dev/null || true
controller_pid=""
"$repo_dir/bin/agenticmode" > "$test_root/registration-restart-new.log" 2>&1 &
controller_pid=$!
wait_for_contains "System sleep is disabled" "$test_root/registration-restart-new.log"
/bin/sleep 4
assert_equals 1 "$(cat "$pmset_state")"
kill -TERM "$controller_pid"
wait_for_exit "$controller_pid"
wait "$controller_pid" 2>/dev/null || true
controller_pid=""
wait_for_value 0 "$pmset_state"

printf 'Test: off drains a registered helper paused before enable\n'
printf '1\n' > "$pmset_state"
after_gate_file="$test_root/watchdog-after-gate.ready"
continue_file="$test_root/watchdog-after-gate.continue"
env AGENTICMODE_TEST_WATCHDOG_AFTER_GATE_FILE="$after_gate_file" \
  AGENTICMODE_TEST_WATCHDOG_CONTINUE_FILE="$continue_file" \
  "$repo_dir/bin/agenticmode" > "$test_root/after-gate-controller.log" 2>&1 &
controller_pid=$!
attempts=0
while [ ! -e "$after_gate_file" ] && [ "$attempts" -lt 80 ]; do
  /bin/sleep 0.1
  attempts=$((attempts + 1))
done
[ -e "$after_gate_file" ] || { printf 'Watchdog gate hook was not reached\n' >&2; exit 1; }
kill -KILL "$controller_pid"
wait "$controller_pid" 2>/dev/null || true
controller_pid=""
"$repo_dir/bin/agenticmode" off > "$test_root/after-gate-off.log" 2>&1 &
child_pid=$!
/bin/sleep 1
kill -0 "$child_pid" 2>/dev/null || { printf 'off did not wait for the registered watchdog\n' >&2; exit 1; }
: > "$continue_file"
wait "$child_pid"
child_pid=""
wait_for_value 0 "$pmset_state"
/bin/sleep 1
assert_equals 0 "$(cat "$pmset_state")"

printf 'Test: watchdog reasserts the override\n'
"$repo_dir/bin/agenticmode" > "$test_root/reassert.log" 2>&1 &
controller_pid=$!
wait_for_contains "System sleep is disabled" "$test_root/reassert.log"
printf '0\n' > "$pmset_state"
wait_for_value 1 "$pmset_state"
kill -TERM "$controller_pid"
wait_for_exit "$controller_pid"
wait "$controller_pid" 2>/dev/null || true
controller_pid=""
wait_for_value 0 "$pmset_state"

printf 'Test: watchdog retries transient restoration failures\n'
printf '0\n' > "$pmset_fail_value_file"
printf '2\n' > "$pmset_fail_count_file"
"$repo_dir/bin/agenticmode" > "$test_root/restore-retry.log" 2>&1 &
controller_pid=$!
wait_for_contains "System sleep is disabled" "$test_root/restore-retry.log"
kill -TERM "$controller_pid"
wait_for_exit "$controller_pid"
wait "$controller_pid" 2>/dev/null || true
controller_pid=""
wait_for_value 0 "$pmset_state"
printf 'none\n' > "$pmset_fail_value_file"
printf '0\n' > "$pmset_fail_count_file"

printf 'Test: failed restoration is reported and recoverable with off\n'
printf '0\n' > "$pmset_fail_value_file"
printf '10\n' > "$pmset_fail_count_file"
"$repo_dir/bin/agenticmode" > "$test_root/restore-failure.log" 2>&1 &
controller_pid=$!
wait_for_contains "System sleep is disabled" "$test_root/restore-failure.log"
kill -TERM "$controller_pid"
set +e
wait "$controller_pid"
restore_status=$?
set -e
controller_pid=""
assert_equals 78 "$restore_status"
assert_equals 1 "$(cat "$pmset_state")"
assert_contains "did not confirm sleep restoration" "$test_root/restore-failure.log"
printf 'none\n' > "$pmset_fail_value_file"
printf '0\n' > "$pmset_fail_count_file"
"$repo_dir/bin/agenticmode" off > "$test_root/restore-failure-off.log" 2>&1
wait_for_value 0 "$pmset_state"

printf 'Test: state transitions use an atomic operating-system lock\n'
operation_ready="$test_root/operation-lock.ready"
env AGENTICMODE_TEST_OPERATION_LOCK_DELAY=3 \
  AGENTICMODE_TEST_OPERATION_LOCK_READY_FILE="$operation_ready" \
  "$repo_dir/bin/agenticmode" off > "$test_root/operation-lock-first.log" 2>&1 &
lock_holder_pid=$!
attempts=0
while [ ! -e "$operation_ready" ] && [ "$attempts" -lt 80 ]; do
  /bin/sleep 0.1
  attempts=$((attempts + 1))
done
[ -e "$operation_ready" ] || { printf 'Operation lock hook was not reached\n' >&2; exit 1; }
operation_started=$(/bin/date +%s)
"$repo_dir/bin/agenticmode" off > "$test_root/operation-lock-second.log" 2>&1
operation_elapsed=$(( $(/bin/date +%s) - operation_started ))
[ "$operation_elapsed" -ge 2 ] || { printf 'Concurrent state transition bypassed the operation lock\n' >&2; exit 1; }
wait "$lock_holder_pid"
assert_equals 0 "$(cat "$pmset_state")"

printf 'Test: no-target current does not call sudo or change power\n'
clear_codex_fixtures
: > "$sudo_log"
: > "$pmset_log"
"$repo_dir/bin/agenticmode" current --no-processes > "$test_root/no-target.log" 2>&1
assert_equals 0 "$(cat "$pmset_state")"
assert_equals 0 "$(wc -l < "$sudo_log" | tr -d ' ')"
assert_contains "Power settings were not changed" "$test_root/no-target.log"

printf 'Test: one-shot detector recognizes wrappers without prompt false positives\n'
agent_bin="$test_root/agent-bin"
mkdir -p "$agent_bin"
for agent_script in claude claude.exe node python opencode opencode.exe myagent; do
  cat > "$agent_bin/$agent_script" <<'AGENT'
#!/bin/bash
/bin/sleep 8
AGENT
  chmod 755 "$agent_bin/$agent_script"
done
"$agent_bin/claude" -p task & claude_pid=$!
"$agent_bin/claude.exe" --print task & claude_exe_pid=$!
"$agent_bin/node" "$agent_bin/gemini.js" --prompt task & gemini_pid=$!
"$agent_bin/python" -m aider --message task & aider_pid=$!
"$agent_bin/opencode" run task & opencode_pid=$!
"$agent_bin/opencode.exe" run task & opencode_exe_pid=$!
"$agent_bin/python" -c claude -p & false_pid=$!
agent_pids="$claude_pid $claude_exe_pid $gemini_pid $aider_pid $opencode_pid $opencode_exe_pid $false_pid"
/bin/sleep 0.2
"$repo_dir/bin/agenticmode" detect --no-codex > "$test_root/process-detect.log" 2>&1
assert_contains "WORKING claude" "$test_root/process-detect.log"
assert_contains "Process $claude_pid - exact PID and start time" "$test_root/process-detect.log"
assert_contains "Process $claude_exe_pid - exact PID and start time" "$test_root/process-detect.log"
assert_contains "WORKING gemini" "$test_root/process-detect.log"
assert_contains "Process $gemini_pid - exact PID and start time" "$test_root/process-detect.log"
assert_contains "WORKING aider" "$test_root/process-detect.log"
assert_contains "Process $aider_pid - exact PID and start time" "$test_root/process-detect.log"
assert_contains "WORKING opencode" "$test_root/process-detect.log"
assert_contains "Process $opencode_pid - exact PID and start time" "$test_root/process-detect.log"
assert_contains "Process $opencode_exe_pid - exact PID and start time" "$test_root/process-detect.log"
if grep -Fq "Process $false_pid" "$test_root/process-detect.log"; then
  printf 'Process detector matched provider text passed to python -c\n' >&2
  exit 1
fi
if LC_ALL=C grep -q $'\033' "$test_root/process-detect.log"; then
  printf 'Redirected output unexpectedly contained terminal color codes\n' >&2
  exit 1
fi
env -u NO_COLOR FORCE_COLOR=1 "$repo_dir/bin/agenticmode" detect --no-codex --no-processes --pid "$claude_pid" > "$test_root/color.log" 2>&1
assert_contains $'\033[36mWORKING' "$test_root/color.log"
NO_COLOR=1 FORCE_COLOR=1 "$repo_dir/bin/agenticmode" detect --no-codex --no-processes --pid "$claude_pid" > "$test_root/no-color.log" 2>&1
if LC_ALL=C grep -q $'\033' "$test_root/no-color.log"; then
  printf 'NO_COLOR output unexpectedly contained terminal color codes\n' >&2
  exit 1
fi
"$agent_bin/myagent" & custom_pid=$!
agent_pids="$agent_pids $custom_pid"
/bin/sleep 0.2
AGENTICMODE_CUSTOM_PROCESS_NAMES=myagent "$repo_dir/bin/agenticmode" detect --no-codex > "$test_root/custom-process.log" 2>&1
assert_contains "WORKING myagent" "$test_root/custom-process.log"
assert_contains "Process $custom_pid - exact PID and start time" "$test_root/custom-process.log"
for agent_pid in $agent_pids; do kill -TERM "$agent_pid" 2>/dev/null || true; done
for agent_pid in $agent_pids; do wait "$agent_pid" 2>/dev/null || true; done
agent_pids=""

printf 'Test: lifecycle activities use exact caller exclusion with shared owners\n'
"$repo_dir/bin/agenticmode" activity start opencode session-a "$$" generation-a
"$repo_dir/bin/agenticmode" activity start opencode session-b "$$" generation-b
AGENTICMODE_CALLER_ACTIVITY_HARNESS=opencode \
  AGENTICMODE_CALLER_ACTIVITY_SOURCE=session-a \
  "$repo_dir/bin/agenticmode" detect --no-codex --no-processes > "$test_root/activity-exclusion.log" 2>&1
assert_contains "Detected 1 active run." "$test_root/activity-exclusion.log"
assert_contains "OpenCode activity session-b" "$test_root/activity-exclusion.log"
assert_not_contains "OpenCode activity session-a" "$test_root/activity-exclusion.log"
"$repo_dir/bin/agenticmode" detect --no-codex --no-processes > "$test_root/activity-owner-fallback.log" 2>&1
assert_contains "Detected 0 active runs." "$test_root/activity-owner-fallback.log"
AGENTICMODE_CALLER_ACTIVITY_HARNESS=opencode \
  AGENTICMODE_CALLER_ACTIVITY_SOURCE=session-a \
  "$repo_dir/bin/agenticmode" detect --no-codex --no-processes --no-activities > "$test_root/activity-disabled.log" 2>&1
assert_contains "Detected 0 active runs." "$test_root/activity-disabled.log"
"$repo_dir/bin/agenticmode" activity stop opencode session-a "$$" generation-a
"$repo_dir/bin/agenticmode" activity stop opencode session-b "$$" generation-b

printf 'Test: activity generations prevent later work from extending a snapshot\n'
"$repo_dir/bin/agenticmode" activity start opencode session-aba "$$" generation-old
AGENTICMODE_CALLER_ACTIVITY_HARNESS=opencode \
  AGENTICMODE_CALLER_ACTIVITY_SOURCE=caller-session \
  "$repo_dir/bin/agenticmode" current --no-codex --no-processes > "$test_root/activity-generation.log" 2>&1 &
controller_pid=$!
wait_for_value 1 "$pmset_state"
wait_for_contains "WORKING OpenCode activity session-aba" "$test_root/activity-generation.log"
"$repo_dir/bin/agenticmode" activity start opencode session-aba "$$" generation-new
wait_for_exit "$controller_pid"
wait "$controller_pid" 2>/dev/null || true
controller_pid=""
wait_for_value 0 "$pmset_state"
assert_contains "ENDED   OpenCode activity session-aba" "$test_root/activity-generation.log"
assert_contains "Tracking complete: the tracked run is no longer active" "$test_root/activity-generation.log"
"$repo_dir/bin/agenticmode" activity stop opencode session-aba "$$" generation-old
AGENTICMODE_CALLER_ACTIVITY_HARNESS=opencode \
  AGENTICMODE_CALLER_ACTIVITY_SOURCE=caller-session \
  "$repo_dir/bin/agenticmode" detect --no-codex --no-processes > "$test_root/activity-stale-stop.log" 2>&1
assert_contains "OpenCode activity session-aba" "$test_root/activity-stale-stop.log"
"$repo_dir/bin/agenticmode" activity stop opencode session-aba "$$" generation-new

printf 'Test: activity publication is atomic under concurrent detection\n'
activity_publish_ready="$test_root/activity-publish.ready"
env AGENTICMODE_TEST_ACTIVITY_PUBLISH_READY_FILE="$activity_publish_ready" \
  AGENTICMODE_TEST_ACTIVITY_PUBLISH_DELAY=1 \
  "$repo_dir/bin/agenticmode" activity start opencode session-atomic "$$" generation-atomic > "$test_root/activity-publish.log" 2>&1 &
child_pid=$!
attempts=0
while [ ! -e "$activity_publish_ready" ] && [ "$attempts" -lt 80 ]; do
  /bin/sleep 0.1
  attempts=$((attempts + 1))
done
[ -e "$activity_publish_ready" ] || { printf 'Activity publication hook was not reached\n' >&2; exit 1; }
AGENTICMODE_CALLER_ACTIVITY_HARNESS=opencode \
  AGENTICMODE_CALLER_ACTIVITY_SOURCE=caller-session \
  "$repo_dir/bin/agenticmode" detect --no-codex --no-processes > "$test_root/activity-atomic.log" 2>&1
wait "$child_pid"
child_pid=""
assert_contains "OpenCode activity session-atomic" "$test_root/activity-atomic.log"
assert_not_contains "malformed activity" "$test_root/activity-atomic.log"
"$repo_dir/bin/agenticmode" activity stop opencode session-atomic "$$" generation-atomic

printf 'Test: dead owners and unsafe activity records are ignored\n'
activity_publisher="$test_root/activity-publisher"
activity_owner_ready="$test_root/activity-owner.ready"
cat > "$activity_publisher" <<'ACTIVITY_PUBLISHER'
#!/bin/bash
set -eu
"$AGENTICMODE_ACTIVITY_REPO/bin/agenticmode" activity start opencode dead-owner "$$" dead-generation
: > "$AGENTICMODE_ACTIVITY_READY"
while :; do /bin/sleep 1; done
ACTIVITY_PUBLISHER
chmod 755 "$activity_publisher"
AGENTICMODE_ACTIVITY_REPO="$repo_dir" AGENTICMODE_ACTIVITY_READY="$activity_owner_ready" "$activity_publisher" &
activity_owner_pid=$!
agent_pids="$activity_owner_pid"
attempts=0
while [ ! -e "$activity_owner_ready" ] && [ "$attempts" -lt 80 ]; do
  /bin/sleep 0.1
  attempts=$((attempts + 1))
done
[ -e "$activity_owner_ready" ] || { printf 'Activity owner did not publish its marker\n' >&2; exit 1; }
AGENTICMODE_CALLER_ACTIVITY_HARNESS=opencode \
  AGENTICMODE_CALLER_ACTIVITY_SOURCE=caller-session \
  "$repo_dir/bin/agenticmode" detect --no-codex --no-processes > "$test_root/activity-live-owner.log" 2>&1
assert_contains "OpenCode activity dead-owner" "$test_root/activity-live-owner.log"
kill -KILL "$activity_owner_pid"
wait "$activity_owner_pid" 2>/dev/null || true
agent_pids=""
AGENTICMODE_CALLER_ACTIVITY_HARNESS=opencode \
  AGENTICMODE_CALLER_ACTIVITY_SOURCE=caller-session \
  "$repo_dir/bin/agenticmode" detect --no-codex --no-processes > "$test_root/activity-dead-owner.log" 2>&1
assert_contains "Detected 0 active runs." "$test_root/activity-dead-owner.log"
rm -f "$state_dir/activities/opencode~dead-owner.activity"
ln -s "$test_root/missing-activity" "$state_dir/activities/opencode~unsafe-link.activity"
printf '%s\n' 'bad|123|not-base64!' > "$state_dir/activities/opencode~unsafe-mode.activity"
chmod 644 "$state_dir/activities/opencode~unsafe-mode.activity"
AGENTICMODE_CALLER_ACTIVITY_HARNESS=opencode \
  AGENTICMODE_CALLER_ACTIVITY_SOURCE=caller-session \
  "$repo_dir/bin/agenticmode" detect --no-codex --no-processes > "$test_root/activity-unsafe.log" 2>&1
assert_contains "Detected 0 active runs." "$test_root/activity-unsafe.log"
assert_contains "ignored unsafe or malformed activity marker" "$test_root/activity-unsafe.log"
rm -f "$state_dir/activities/opencode~unsafe-link.activity" "$state_dir/activities/opencode~unsafe-mode.activity"

printf 'Test: current deduplicates Codex copies and ignores later turns\n'
parent_fixture="$codex_home/sessions/2026/08/11/rollout-parent.jsonl"
sub_fixture="$codex_home/sessions/2026/08/11/rollout-sub.jsonl"
/usr/bin/sqlite3 "$codex_home/state_5.sqlite" \
  "create table threads (rollout_path text primary key, title text not null); insert into threads values ('$parent_fixture', 'Merge PRs and improve docs' || char(27)); insert into threads values ('$sub_fixture', 'Update version and release notes');"
printf '%s\n' '{"timestamp":"2026-08-11T00:00:00Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-parent"}}' > "$parent_fixture"
/bin/sleep 1
printf '%s\n' \
  '{"timestamp":"2026-08-11T00:00:00Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-parent"}}' \
  '{"timestamp":"2026-08-11T00:00:01Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-sub"}}' > "$sub_fixture"
"$repo_dir/bin/agenticmode" current --no-processes > "$test_root/current.log" 2>&1 &
controller_pid=$!
wait_for_value 1 "$pmset_state"
wait_for_contains "Tracking 2 current agent runs" "$test_root/current.log"
wait_for_contains "WORKING Merge PRs and improve docs" "$test_root/current.log"
wait_for_contains "WORKING Update version and release notes" "$test_root/current.log"
wait_for_contains "Progress: 2 working - 0/2 no longer active (0% by run count)" "$test_root/current.log"
assert_not_contains "Codex turn turn-parent" "$test_root/current.log"
assert_not_contains "Codex turn turn-sub" "$test_root/current.log"
if LC_ALL=C grep -q $'\033' "$test_root/current.log"; then
  printf 'Codex session title leaked terminal control codes\n' >&2
  exit 1
fi
printf '%s\n' '{"timestamp":"2026-08-11T00:00:01Z","type":"event_msg","payload":{"type":"note"}}' >> "$parent_fixture"
wait_for_contains "|" "$state_dir/codex-offsets/turn-parent"
printf '%s\n' '{"timestamp":"2026-08-11T00:00:02Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-later"}}' >> "$parent_fixture"
printf '%s\n' '{"timestamp":"2026-08-11T00:00:03Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-parent"}}' >> "$parent_fixture"
wait_for_contains "Progress: 1 working - 1/2 no longer active (50% by run count)" "$test_root/current.log"
assert_contains "DONE    Merge PRs and improve docs" "$test_root/current.log"
assert_occurrences 1 "Update version and release notes" "$test_root/current.log"
"$repo_dir/bin/agenticmode" status --verbose > "$test_root/current-status.log" 2>&1
assert_contains "Progress: 1 working - 1/2 no longer active (50% by run count)" "$test_root/current-status.log"
assert_contains "DONE    Merge PRs and improve docs" "$test_root/current-status.log"
assert_contains "WORKING Update version and release notes" "$test_root/current-status.log"
assert_contains "Codex turn turn-parent - exact lifecycle" "$test_root/current-status.log"
"$repo_dir/bin/agenticmode" status --machine > "$test_root/current-machine-status.log" 2>&1
assert_equals "sleep_disabled
controller
mode
controller_pid
started
restore_baseline
watchdog
watchdog_pid
tracked_runs_remaining" "$(cut -d= -f1 "$test_root/current-machine-status.log")"
assert_contains "controller=active" "$test_root/current-machine-status.log"
assert_contains "tracked_runs_remaining=1" "$test_root/current-machine-status.log"
if "$repo_dir/bin/agenticmode" status --verbose --machine > "$test_root/status-conflicting-formats.log" 2>&1; then
  printf 'Conflicting status formats unexpectedly succeeded\n' >&2
  exit 1
fi
assert_contains "--verbose and --machine cannot be combined" "$test_root/status-conflicting-formats.log"
printf '%s\n' '{"timestamp":"2026-08-11T00:00:04Z","type":"event_msg","payload":{"type":"turn_aborted","turn_id":"turn-sub"}}' >> "$sub_fixture"
wait_for_exit "$controller_pid"
wait "$controller_pid" 2>/dev/null || true
controller_pid=""
wait_for_value 0 "$pmset_state"
assert_contains "Tracking complete: all 2 tracked runs are no longer active" "$test_root/current.log"
assert_contains "ABORTED Update version and release notes" "$test_root/current.log"
assert_occurrences 2 "Update version and release notes" "$test_root/current.log"

printf 'Test: caller thread exclusion prevents self-deadlock\n'
clear_codex_fixtures
self_fixture="$codex_home/sessions/2026/08/11/rollout-thread-self.jsonl"
printf '%s\n' '{"timestamp":"2026-08-11T00:00:00Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-self"}}' > "$self_fixture"
env -u CODEX_THREAD_ID AGENTICMODE_EXCLUDE_CODEX_THREAD_IDS=thread-self "$repo_dir/bin/agenticmode" detect --no-processes > "$test_root/exclusion.log" 2>&1
assert_contains "Detected 0 active runs." "$test_root/exclusion.log"
clear_codex_fixtures

printf 'Test: exact PID wait mode\n'
/bin/sleep 2 &
child_pid=$!
"$repo_dir/bin/agenticmode" wait "$child_pid" > "$test_root/wait.log" 2>&1 &
controller_pid=$!
wait_for_value 1 "$pmset_state"
wait "$child_pid"
child_pid=""
wait_for_exit "$controller_pid"
wait "$controller_pid" 2>/dev/null || true
controller_pid=""
wait_for_value 0 "$pmset_state"
assert_contains "ENDED   sleep" "$test_root/wait.log"
assert_contains "Tracking complete: the tracked run is no longer active" "$test_root/wait.log"

printf 'Test: exact command mode preserves exit status\n'
set +e
"$repo_dir/bin/agenticmode" run -- /bin/sh -c 'sleep 1; exit 7' > "$test_root/run.log" 2>&1
run_status=$?
set -e
assert_equals 7 "$run_status"
assert_contains "FAILED  Command exited with status 7" "$test_root/run.log"
wait_for_value 0 "$pmset_state"

printf 'Test: wrapped command arguments do not become agenticmode config\n'
"$repo_dir/bin/agenticmode" run -- /bin/sh -c 'test "$1" = "--config"' child --config > "$test_root/run-config-argument.log" 2>&1
wait_for_value 0 "$pmset_state"

printf 'Test: run cutoff is nonzero and leaves the child running\n'
run_marker="$test_root/run-cutoff-finished"
set +e
"$repo_dir/bin/agenticmode" run --timeout 1s -- /bin/sh -c 'sleep 6; printf present > "$1"' child "$run_marker" > "$test_root/run-cutoff.log" 2>&1
cutoff_status=$?
set -e
assert_equals 75 "$cutoff_status"
[ ! -e "$run_marker" ] || { printf 'Wrapped command had already finished at cutoff\n' >&2; exit 1; }
wait_for_value 0 "$pmset_state"
wait_for_value "present" "$run_marker"

printf 'Test: timeout restores sleep\n'
"$repo_dir/bin/agenticmode" --timeout 1s > "$test_root/timeout.log" 2>&1 &
controller_pid=$!
wait_for_value 1 "$pmset_state"
wait_for_exit "$controller_pid"
set +e
wait "$controller_pid"
timeout_status=$?
set -e
controller_pid=""
assert_equals 75 "$timeout_status"
wait_for_value 0 "$pmset_state"
assert_contains "Maximum duration reached" "$test_root/timeout.log"

printf 'Test: minimum battery cutoff restores sleep\n'
printf 'Battery Power\n' > "$power_source_file"
printf '80\n' > "$battery_percent_file"
"$repo_dir/bin/agenticmode" --min-battery 50 > "$test_root/battery.log" 2>&1 &
controller_pid=$!
wait_for_value 1 "$pmset_state"
printf '50\n' > "$battery_percent_file"
wait_for_exit "$controller_pid"
set +e
wait "$controller_pid"
battery_status=$?
set -e
controller_pid=""
assert_equals 75 "$battery_status"
wait_for_value 0 "$pmset_state"
assert_contains "Battery reached 50%" "$test_root/battery.log"
printf 'AC Power\n' > "$power_source_file"

printf 'Test: minimum battery protection fails closed on unknown data\n'
printf 'Unknown Power\n' > "$power_source_file"
set +e
"$repo_dir/bin/agenticmode" --min-battery 50 > "$test_root/battery-unknown.log" 2>&1
battery_unknown_status=$?
set -e
assert_equals 75 "$battery_unknown_status"
wait_for_value 0 "$pmset_state"
assert_contains "Battery state could not be read" "$test_root/battery-unknown.log"
printf 'Battery Power\n' > "$power_source_file"
printf 'unknown\n' > "$battery_percent_file"
set +e
"$repo_dir/bin/agenticmode" --min-battery 50 > "$test_root/battery-malformed.log" 2>&1
battery_malformed_status=$?
set -e
assert_equals 75 "$battery_malformed_status"
wait_for_value 0 "$pmset_state"
assert_contains "Battery percentage could not be read" "$test_root/battery-malformed.log"
printf '100\n' > "$battery_percent_file"
printf 'AC Power\n' > "$power_source_file"

printf 'Test: strict config parsing and precedence\n'
config_file="$test_root/config"
printf '%s\n' 'poll_seconds=7' 'timeout=2h' 'min_battery=20' 'include_activities=0' > "$config_file"
chmod 644 "$config_file"
config_output=$(AGENTICMODE_POLL_SECONDS=3 "$repo_dir/bin/agenticmode" config --config "$config_file" --poll 2)
assert_equals 2 "$(printf '%s\n' "$config_output" | sed -n 's/^poll_seconds=//p')"
assert_equals 0 "$(printf '%s\n' "$config_output" | sed -n 's/^include_activities=//p')"
malicious_config="$test_root/malicious-config"
printf '%s\n' 'min_battery=$(touch /tmp/agenticmode-must-not-execute)' > "$malicious_config"
chmod 644 "$malicious_config"
rm -f /tmp/agenticmode-must-not-execute
if "$repo_dir/bin/agenticmode" config --config "$malicious_config" > "$test_root/malicious.log" 2>&1; then
  printf 'Malicious config unexpectedly succeeded\n' >&2
  exit 1
fi
[ ! -e /tmp/agenticmode-must-not-execute ] || { printf 'Config text was executed\n' >&2; exit 1; }
chmod 666 "$config_file"
if "$repo_dir/bin/agenticmode" config --config "$config_file" > "$test_root/permissions.log" 2>&1; then
  printf 'Unsafe config permissions unexpectedly succeeded\n' >&2
  exit 1
fi
AGENTICMODE_CONFIG="$config_file" "$repo_dir/bin/agenticmode" --help > "$test_root/help.log" 2>&1
if "$repo_dir/bin/agenticmode" --timeout 999999999999h > "$test_root/huge-duration.log" 2>&1; then
  printf 'Oversized duration unexpectedly succeeded\n' >&2
  exit 1
fi

printf 'Test: controller conflicts fail without skipping a wrapped command\n'
export AGENTICMODE_CONFIG="$test_root/missing-config"
"$repo_dir/bin/agenticmode" --poll 300 > "$test_root/off-active.log" 2>&1 &
controller_pid=$!
wait_for_contains "System sleep is disabled" "$test_root/off-active.log"
conflict_marker="$test_root/conflict-command-ran"
if "$repo_dir/bin/agenticmode" run -- /usr/bin/touch "$conflict_marker" > "$test_root/conflict.log" 2>&1; then
  printf 'Conflicting run unexpectedly succeeded\n' >&2
  exit 1
fi
[ ! -e "$conflict_marker" ] || { printf 'Conflicting wrapped command unexpectedly ran\n' >&2; exit 1; }

printf 'Test: off interrupts a controller with a long poll and is idempotent\n'
off_started=$(/bin/date +%s)
"$repo_dir/bin/agenticmode" off > "$test_root/off.log" 2>&1
off_elapsed=$(( $(/bin/date +%s) - off_started ))
[ "$off_elapsed" -lt 10 ] || { printf 'off took too long with a 300-second poll\n' >&2; exit 1; }
wait_for_exit "$controller_pid"
wait "$controller_pid" 2>/dev/null || true
controller_pid=""
wait_for_value 0 "$pmset_state"
"$repo_dir/bin/agenticmode" off >> "$test_root/off.log" 2>&1
assert_equals 0 "$(cat "$pmset_state")"
"$repo_dir/bin/agenticmode" status --machine > "$test_root/inactive-machine-status.log" 2>&1
assert_equals "sleep_disabled=0
controller=inactive" "$(cat "$test_root/inactive-machine-status.log")"

printf 'Test: installer ownership checks and custom-prefix uninstall\n'
install_prefix="$test_root/prefix with space"
PREFIX="$install_prefix" "$repo_dir/install.sh" > "$test_root/install.log" 2>&1
assert_equals "$repo_dir/bin/agenticmode" "$(readlink "$install_prefix/bin/agenticmode")"
assert_equals "$repo_dir/bin/agenticmode" "$(readlink "$install_prefix/bin/am")"
assert_equals "agenticmode 1.3.0" "$("$install_prefix/bin/am" --version)"
PREFIX="$install_prefix" "$repo_dir/install.sh" >> "$test_root/install.log" 2>&1
rm "$install_prefix/bin/am"
ln -s /tmp/unrelated-am "$install_prefix/bin/am"
if PREFIX="$install_prefix" "$repo_dir/install.sh" >> "$test_root/install.log" 2>&1; then
  printf 'Installer unexpectedly replaced an unrelated am symlink\n' >&2
  exit 1
fi
assert_equals "$repo_dir/bin/agenticmode" "$(readlink "$install_prefix/bin/agenticmode")"
PREFIX="$install_prefix" "$repo_dir/install.sh" --force >> "$test_root/install.log" 2>&1
rm "$install_prefix/bin/agenticmode"
ln -s /tmp/unrelated-agenticmode "$install_prefix/bin/agenticmode"
if PREFIX="$install_prefix" "$repo_dir/install.sh" >> "$test_root/install.log" 2>&1; then
  printf 'Installer unexpectedly replaced an unrelated symlink\n' >&2
  exit 1
fi
PREFIX="$install_prefix" "$repo_dir/install.sh" --force >> "$test_root/install.log" 2>&1
PREFIX="$install_prefix" "$repo_dir/uninstall.sh" > "$test_root/uninstall.log" 2>&1
[ ! -e "$install_prefix/bin/agenticmode" ] || { printf 'Uninstaller left the custom-prefix symlink behind\n' >&2; exit 1; }
[ ! -e "$install_prefix/bin/am" ] || { printf 'Uninstaller left the custom-prefix am symlink behind\n' >&2; exit 1; }

printf 'Test: remote bootstrap install is persistent and removable\n'
remote_root="$test_root/managed source"
remote_prefix="$test_root/remote prefix"
empty_working_dir="$test_root/empty working directory"
mkdir -p "$empty_working_dir"
(
  cd "$empty_working_dir"
  PREFIX="$remote_prefix" \
    AGENTICMODE_INSTALL_DIR="$remote_root" \
    AGENTICMODE_INSTALL_BASE_URL="file://$repo_dir" \
    /bin/bash < "$repo_dir/install.sh"
) > "$test_root/remote-install.log" 2>&1
remote_root_canonical=$(CDPATH= cd -- "$remote_root" && pwd)
assert_equals "$remote_root_canonical/bin/agenticmode" "$(readlink "$remote_prefix/bin/agenticmode")"
assert_equals "$remote_root_canonical/bin/agenticmode" "$(readlink "$remote_prefix/bin/am")"
assert_equals "agenticmode 1.3.0" "$("$remote_prefix/bin/agenticmode" --version)"
assert_equals "agenticmode 1.3.0" "$("$remote_prefix/bin/am" --version)"
[ -f "$remote_root/.agenticmode-remote-install" ] || { printf 'Remote installer marker was not created\n' >&2; exit 1; }
assert_equals "agenticmode-remote-install:v2
stable
$remote_root_canonical
$remote_prefix" "$(cat "$remote_root/.agenticmode-remote-install")"

printf 'agenticmode-remote-install:main\n%s\n' "$remote_root_canonical" > "$remote_root/.agenticmode-remote-install"
chmod 600 "$remote_root/.agenticmode-remote-install"
PREFIX="$remote_prefix" "$remote_root/install.sh" > "$test_root/legacy-marker-migration.log" 2>&1
assert_equals "agenticmode-remote-install:v2
stable
$remote_root_canonical
$remote_prefix" "$(cat "$remote_root/.agenticmode-remote-install")"

printf 'Test: managed updates verify releases and preserve the current install on failure\n'
release_source="$test_root/release source"
release_base="$test_root/releases"
mkdir -p "$release_source/bin" "$release_source/libexec" "$release_source/scripts" "$release_base/latest/download"
cp "$repo_dir/install.sh" "$release_source/install.sh"
cp "$repo_dir/uninstall.sh" "$release_source/uninstall.sh"
cp "$repo_dir/config.example" "$release_source/config.example"
cp "$repo_dir/bin/agenticmode" "$release_source/bin/agenticmode"
cp "$repo_dir/libexec/agenticmode-watchdog" "$release_source/libexec/agenticmode-watchdog"
cp "$repo_dir/scripts/package-release.sh" "$release_source/scripts/package-release.sh"
sed 's/readonly AGENTICMODE_VERSION="1.3.0"/readonly AGENTICMODE_VERSION="1.3.1"/' \
  "$release_source/bin/agenticmode" > "$release_source/bin/agenticmode.next"
mv "$release_source/bin/agenticmode.next" "$release_source/bin/agenticmode"
chmod 755 "$release_source/bin/agenticmode" "$release_source/scripts/package-release.sh"
"$release_source/scripts/package-release.sh" v1.3.1 "$release_base/latest/download" > "$test_root/package-release.log"

"$repo_dir/bin/agenticmode" > "$test_root/update-active-controller.log" 2>&1 &
controller_pid=$!
wait_for_value 1 "$pmset_state"
if AGENTICMODE_TEST_RELEASE_BASE_URL="file://$release_base" "$remote_prefix/bin/am" update > "$test_root/update-active.log" 2>&1; then
  printf 'Update unexpectedly ran while agentic mode was active\n' >&2
  exit 1
fi
assert_contains "agentic mode is active" "$test_root/update-active.log"
"$repo_dir/bin/agenticmode" off > "$test_root/update-active-off.log" 2>&1
wait_for_exit "$controller_pid"
wait "$controller_pid" 2>/dev/null || true
controller_pid=""
wait_for_value 0 "$pmset_state"

corrupt_release_base="$test_root/corrupt-releases"
mkdir -p "$corrupt_release_base/latest/download"
cp "$release_base/latest/download/agenticmode.tar.gz" "$corrupt_release_base/latest/download/agenticmode.tar.gz"
cp "$release_base/latest/download/agenticmode.tar.gz.sha256" "$corrupt_release_base/latest/download/agenticmode.tar.gz.sha256"
printf 'tampered\n' >> "$corrupt_release_base/latest/download/agenticmode.tar.gz"
if AGENTICMODE_TEST_RELEASE_BASE_URL="file://$corrupt_release_base" "$remote_prefix/bin/am" update > "$test_root/update-corrupt.log" 2>&1; then
  printf 'Update unexpectedly accepted a corrupt release archive\n' >&2
  exit 1
fi
assert_contains "checksum did not match" "$test_root/update-corrupt.log"
assert_equals "agenticmode 1.3.0" "$("$remote_prefix/bin/agenticmode" --version)"

AGENTICMODE_TEST_RELEASE_BASE_URL="file://$release_base" "$remote_prefix/bin/am" update > "$test_root/update-success.log" 2>&1
assert_contains "Updated agenticmode 1.3.0 -> 1.3.1" "$test_root/update-success.log"
assert_equals "agenticmode 1.3.1" "$("$remote_prefix/bin/agenticmode" --version)"
assert_equals "agenticmode 1.3.1" "$("$remote_prefix/bin/am" --version)"
AGENTICMODE_TEST_RELEASE_BASE_URL="file://$release_base" "$remote_prefix/bin/agenticmode" update > "$test_root/update-current.log" 2>&1
assert_contains "already the latest stable release" "$test_root/update-current.log"

rollback_release_base="$test_root/rollback-releases"
mkdir -p "$rollback_release_base/latest/download"
sed 's/readonly AGENTICMODE_VERSION="1.3.1"/readonly AGENTICMODE_VERSION="1.3.2"/' \
  "$release_source/bin/agenticmode" > "$release_source/bin/agenticmode.next"
mv "$release_source/bin/agenticmode.next" "$release_source/bin/agenticmode"
chmod 755 "$release_source/bin/agenticmode"
printf '\n[ "${AGENTICMODE_TESTING:-0}" != "1" ] || exit 42\n' >> "$release_source/install.sh"
"$release_source/scripts/package-release.sh" v1.3.2 "$rollback_release_base/latest/download" > "$test_root/package-rollback-release.log"
if AGENTICMODE_TEST_RELEASE_BASE_URL="file://$rollback_release_base" "$remote_prefix/bin/am" update > "$test_root/update-rollback.log" 2>&1; then
  printf 'Update unexpectedly succeeded when the staged installer failed\n' >&2
  exit 1
fi
assert_contains "previous managed files were restored" "$test_root/update-rollback.log"
assert_equals "agenticmode 1.3.1" "$("$remote_prefix/bin/agenticmode" --version)"

incomplete_rollback_release_base="$test_root/incomplete-rollback-releases"
mkdir -p "$incomplete_rollback_release_base/latest/download"
cp "$repo_dir/install.sh" "$release_source/install.sh"
sed 's/readonly AGENTICMODE_VERSION="1.3.2"/readonly AGENTICMODE_VERSION="1.3.3"/' \
  "$release_source/bin/agenticmode" > "$release_source/bin/agenticmode.next"
mv "$release_source/bin/agenticmode.next" "$release_source/bin/agenticmode"
chmod 755 "$release_source/bin/agenticmode"
printf '\nif [ "${AGENTICMODE_TESTING:-0}" = "1" ]; then chmod 500 "$script_dir/bin"; exit 42; fi\n' >> "$release_source/install.sh"
"$release_source/scripts/package-release.sh" v1.3.3 "$incomplete_rollback_release_base/latest/download" > "$test_root/package-incomplete-rollback-release.log"
cp "$remote_root/bin/agenticmode" "$test_root/agenticmode-before-incomplete-rollback"
if AGENTICMODE_TEST_RELEASE_BASE_URL="file://$incomplete_rollback_release_base" "$remote_prefix/bin/am" update > "$test_root/update-incomplete-rollback.log" 2>&1; then
  printf 'Update unexpectedly succeeded when rollback was incomplete\n' >&2
  exit 1
fi
assert_contains "rollback was incomplete; reinstall agenticmode before running it again" "$test_root/update-incomplete-rollback.log"
chmod 755 "$remote_root/bin"
/usr/bin/install -m 755 "$test_root/agenticmode-before-incomplete-rollback" "$remote_root/bin/agenticmode"
assert_equals "agenticmode 1.3.1" "$("$remote_prefix/bin/agenticmode" --version)"
sed 's/readonly AGENTICMODE_VERSION="1.3.3"/readonly AGENTICMODE_VERSION="1.3.2"/' \
  "$release_source/bin/agenticmode" > "$release_source/bin/agenticmode.next"
mv "$release_source/bin/agenticmode.next" "$release_source/bin/agenticmode"
chmod 755 "$release_source/bin/agenticmode"

syntax_release_base="$test_root/syntax-releases"
mkdir -p "$syntax_release_base/latest/download"
cp "$repo_dir/install.sh" "$release_source/install.sh"
printf '\ninvalid (\n' >> "$release_source/install.sh"
"$release_source/scripts/package-release.sh" v1.3.2 "$syntax_release_base/latest/download" > "$test_root/package-syntax-release.log"
if AGENTICMODE_TEST_RELEASE_BASE_URL="file://$syntax_release_base" "$remote_prefix/bin/am" update > "$test_root/update-syntax.log" 2>&1; then
  printf 'Update unexpectedly accepted a release with invalid shell syntax\n' >&2
  exit 1
fi
assert_contains "failed shell syntax validation" "$test_root/update-syntax.log"
assert_equals "agenticmode 1.3.1" "$("$remote_prefix/bin/agenticmode" --version)"

cp "$remote_root/.agenticmode-remote-install" "$test_root/managed-marker"
printf 'agenticmode-remote-install:v2\npinned:v1.3.1\n%s\n%s\n' "$remote_root_canonical" "$remote_prefix" > "$remote_root/.agenticmode-remote-install"
chmod 600 "$remote_root/.agenticmode-remote-install"
if AGENTICMODE_TEST_RELEASE_BASE_URL="file://$release_base" "$remote_prefix/bin/am" update > "$test_root/update-pinned.log" 2>&1; then
  printf 'Update unexpectedly changed a pinned direct install\n' >&2
  exit 1
fi
assert_contains "pinned to v1.3.1" "$test_root/update-pinned.log"
mv "$test_root/managed-marker" "$remote_root/.agenticmode-remote-install"

chmod 666 "$remote_root/.agenticmode-remote-install"
if AGENTICMODE_TEST_RELEASE_BASE_URL="file://$release_base" "$remote_prefix/bin/am" update > "$test_root/update-marker-mode.log" 2>&1; then
  printf 'Update unexpectedly trusted writable managed metadata\n' >&2
  exit 1
fi
assert_contains "must not be group- or world-writable" "$test_root/update-marker-mode.log"
chmod 600 "$remote_root/.agenticmode-remote-install"
mv "$remote_root/.agenticmode-remote-install" "$test_root/managed-marker"
ln -s "$test_root/managed-marker" "$remote_root/.agenticmode-remote-install"
if AGENTICMODE_TEST_RELEASE_BASE_URL="file://$release_base" "$remote_prefix/bin/am" update > "$test_root/update-marker-link.log" 2>&1; then
  printf 'Update unexpectedly trusted symlinked managed metadata\n' >&2
  exit 1
fi
assert_contains "not a regular file" "$test_root/update-marker-link.log"
rm "$remote_root/.agenticmode-remote-install"
mv "$test_root/managed-marker" "$remote_root/.agenticmode-remote-install"

printf 'Test: Homebrew-owned updates delegate exact operations to brew\n'
brew_log="$test_root/brew.log"
cat > "$mock_bin/brew" <<'MOCK'
#!/bin/bash
printf '%s\n' "$*" >> "$AGENTICMODE_TEST_BREW_LOG"
case "${1:-}" in
  --prefix) printf '%s\n' "$AGENTICMODE_TEST_BREW_PREFIX" ;;
  update) ;;
  upgrade) ;;
  *) exit 1 ;;
esac
MOCK
chmod 755 "$mock_bin/brew"
mv "$remote_root/.agenticmode-remote-install" "$test_root/managed-marker"
AGENTICMODE_TEST_BREW_LOG="$brew_log" \
  AGENTICMODE_TEST_BREW_PREFIX="$remote_root_canonical" \
  AGENTICMODE_BREW_BIN="$mock_bin/brew" \
  "$remote_prefix/bin/am" update > "$test_root/update-brew.log" 2>&1
assert_occurrences 2 "--prefix ariakalantari/agenticmode/agenticmode" "$brew_log"
assert_contains "update" "$brew_log"
assert_contains "upgrade --formula ariakalantari/agenticmode/agenticmode" "$brew_log"
mv "$test_root/managed-marker" "$remote_root/.agenticmode-remote-install"

if "$repo_dir/bin/agenticmode" update > "$test_root/update-checkout.log" 2>&1; then
  printf 'Update unexpectedly changed a source checkout\n' >&2
  exit 1
fi
assert_contains "cannot safely update this installation" "$test_root/update-checkout.log"

PREFIX="$remote_prefix" "$remote_root/uninstall.sh" > "$test_root/remote-uninstall.log" 2>&1
[ ! -e "$remote_prefix/bin/agenticmode" ] || { printf 'Remote uninstaller left the command symlink behind\n' >&2; exit 1; }
[ ! -e "$remote_prefix/bin/am" ] || { printf 'Remote uninstaller left the am symlink behind\n' >&2; exit 1; }
[ ! -e "$remote_root" ] || { printf 'Remote uninstaller left the managed source behind\n' >&2; exit 1; }

printf 'All tests passed.\n'
