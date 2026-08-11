#!/bin/bash

set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_root=$(mktemp -d "${TMPDIR:-/tmp}/agenticmode-test.XXXXXX")
mock_bin="$test_root/bin"
state_dir="$test_root/state"
pmset_state="$test_root/pmset-state"
codex_home="$test_root/codex"
controller_pid=""

cleanup() {
  if [ -n "$controller_pid" ]; then
    kill -TERM "$controller_pid" 2>/dev/null || true
    wait "$controller_pid" 2>/dev/null || true
  fi
  rm -rf "$test_root"
}
trap cleanup EXIT INT TERM

mkdir -p "$mock_bin" "$codex_home/sessions/2026/08/11"
printf '0\n' > "$pmset_state"

cat > "$mock_bin/pmset" <<'MOCK'
#!/bin/bash
set -u
if [ "${1:-}" = "-g" ] && [ "${2:-}" = "batt" ]; then
  printf "Now drawing from 'AC Power'\n"
  printf ' -InternalBattery-0 100%%\n'
elif [ "${1:-}" = "-g" ]; then
  printf ' SleepDisabled %s\n' "$(cat "$AGENTICMODE_TEST_PMSET_STATE")"
elif [ "${1:-}" = "-a" ] && [ "${2:-}" = "disablesleep" ]; then
  printf '%s\n' "$3" > "$AGENTICMODE_TEST_PMSET_STATE"
else
  exit 1
fi
MOCK

cat > "$mock_bin/sudo" <<'MOCK'
#!/bin/bash
exec "$@"
MOCK

chmod 755 "$mock_bin/pmset" "$mock_bin/sudo"

export AGENTICMODE_TESTING=1
export AGENTICMODE_PMSET_BIN="$mock_bin/pmset"
export AGENTICMODE_SUDO_BIN="$mock_bin/sudo"
export AGENTICMODE_STATE_DIR="$state_dir"
export AGENTICMODE_TEST_PMSET_STATE="$pmset_state"
export AGENTICMODE_CODEX_HOME="$codex_home"

assert_equals() {
  if [ "$1" != "$2" ]; then
    printf 'Expected "%s", got "%s"\n' "$1" "$2" >&2
    exit 1
  fi
}

wait_for_value() {
  expected="$1"
  file="$2"
  attempts=0
  while [ "$attempts" -lt 50 ]; do
    actual=$(cat "$file" 2>/dev/null || true)
    [ "$actual" = "$expected" ] && return 0
    /bin/sleep 0.1
    attempts=$((attempts + 1))
  done
  printf 'Timed out waiting for %s in %s\n' "$expected" "$file" >&2
  exit 1
}

printf 'Test: syntax\n'
/bin/bash -n "$repo_dir/bin/agenticmode" "$repo_dir/install.sh" "$repo_dir/uninstall.sh"

printf 'Test: indefinite mode and signal cleanup\n'
"$repo_dir/bin/agenticmode" > "$test_root/indefinite.log" 2>&1 &
controller_pid=$!
wait_for_value 1 "$pmset_state"
kill -TERM "$controller_pid"
wait "$controller_pid" 2>/dev/null || true
controller_pid=""
wait_for_value 0 "$pmset_state"

printf 'Test: off is idempotent\n'
"$repo_dir/bin/agenticmode" off > "$test_root/off.log" 2>&1
assert_equals 0 "$(cat "$pmset_state")"

printf 'Test: current mode waits for the exact Codex turn\n'
fixture="$codex_home/sessions/2026/08/11/rollout-test.jsonl"
printf '%s\n' '{"timestamp":"2026-08-11T00:00:00Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-current"}}' > "$fixture"
"$repo_dir/bin/agenticmode" current > "$test_root/current.log" 2>&1 &
controller_pid=$!
wait_for_value 1 "$pmset_state"
/bin/sleep 0.3
kill -0 "$controller_pid"
printf '%s\n' '{"timestamp":"2026-08-11T00:00:01Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-later"}}' >> "$fixture"
printf '%s\n' '{"timestamp":"2026-08-11T00:00:02Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-current"}}' >> "$fixture"

attempts=0
while kill -0 "$controller_pid" 2>/dev/null && [ "$attempts" -lt 80 ]; do
  /bin/sleep 0.1
  attempts=$((attempts + 1))
done
if kill -0 "$controller_pid" 2>/dev/null; then
  printf 'current mode did not finish after its snapshotted turn completed\n' >&2
  exit 1
fi
wait "$controller_pid" 2>/dev/null || true
controller_pid=""
wait_for_value 0 "$pmset_state"

printf 'All tests passed.\n'
