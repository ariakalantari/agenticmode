#!/bin/bash

set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_root=$(mktemp -d "${TMPDIR:-/tmp}/agenticmode-menu-test.XXXXXX")
state_dir="$test_root/state"
mock_bin="$test_root/bin"
pmset_state="$test_root/pmset-state"
pmset_log="$test_root/pmset.log"
helper="$test_root/fake-ui"
helper_response="$test_root/choice"
helper_request="$test_root/request"
mkdir -p "$state_dir" "$mock_bin"
printf '0\n' > "$pmset_state"
: > "$pmset_log"

cleanup() {
  [ -z "${target_pid:-}" ] || kill -TERM "$target_pid" 2>/dev/null || true
  [ -z "${controller_pid:-}" ] || kill -TERM "$controller_pid" 2>/dev/null || true
  rm -rf "$test_root"
}
trap cleanup EXIT INT TERM

cat > "$mock_bin/pmset" <<'MOCK_PMSET'
#!/bin/bash
printf '%s\n' "$*" >> "$AGENTICMODE_TEST_PMSET_LOG"
if [ "${1:-}" = "-g" ] && [ "${2:-}" = "batt" ]; then
  source=$(cat "$AGENTICMODE_TEST_POWER_SOURCE")
  percent=$(cat "$AGENTICMODE_TEST_BATTERY_PERCENT")
  printf "Now drawing from '%s'\n -InternalBattery-0 %s%%; charged\n" "$source" "$percent"
elif [ "${1:-}" = "-g" ]; then
  printf ' SleepDisabled %s\n' "$(cat "$AGENTICMODE_TEST_PMSET_STATE")"
elif [ "${1:-}" = "-a" ] && [ "${2:-}" = "disablesleep" ]; then
  printf '%s\n' "$3" > "$AGENTICMODE_TEST_PMSET_STATE"
else
  exit 1
fi
MOCK_PMSET

cat > "$mock_bin/sudo" <<'MOCK_SUDO'
#!/bin/bash
[ "${1:-}" != "-v" ] || exit 0
exec "$@"
MOCK_SUDO

cat > "$helper" <<'MOCK_HELPER'
#!/bin/bash
set -eu
case "${1:-}" in
  --protocol-version) printf '1\n'; exit 0 ;;
  --version) printf 'agenticmode-ui 1.4.0\n'; exit 0 ;;
esac
[ "$1" = "menu" ]
[ ! -e "$3" ]
if [ -n "${AGENTICMODE_TEST_MENU_BLOCK_READY:-}" ]; then
  printf '%s\n' "$$" > "$AGENTICMODE_TEST_MENU_BLOCK_PID"
  : > "$AGENTICMODE_TEST_MENU_BLOCK_READY"
  trap 'exit 0' TERM INT HUP
  while :; do /bin/sleep 1; done
fi
cp "$2" "$AGENTICMODE_TEST_MENU_REQUEST"
cp "$AGENTICMODE_TEST_MENU_RESPONSE" "$3"
chmod 600 "$3"
MOCK_HELPER
chmod 755 "$mock_bin/pmset" "$mock_bin/sudo" "$helper"

export AGENTICMODE_TESTING=1
export AGENTICMODE_PMSET_BIN="$mock_bin/pmset"
export AGENTICMODE_SUDO_BIN="$mock_bin/sudo"
export AGENTICMODE_WATCHDOG_BIN="$repo_dir/libexec/agenticmode-watchdog"
export AGENTICMODE_STATE_DIR="$state_dir"
export AGENTICMODE_TEST_PMSET_STATE="$pmset_state"
export AGENTICMODE_TEST_PMSET_LOG="$pmset_log"
export AGENTICMODE_TEST_POWER_SOURCE="$test_root/power"
export AGENTICMODE_TEST_BATTERY_PERCENT="$test_root/battery"
export AGENTICMODE_TEST_PMSET_FAIL_VALUE="$test_root/fail-value"
export AGENTICMODE_TEST_PMSET_FAIL_COUNT="$test_root/fail-count"
export AGENTICMODE_TEST_SUDO_LOG="$test_root/sudo.log"
export AGENTICMODE_TEST_WATCHDOG_LOG="$test_root/watchdog.log"
export AGENTICMODE_CODEX_HOME="$test_root/codex"
export AGENTICMODE_CONFIG="$test_root/no-config"
export AGENTICMODE_UI_BIN="$helper"
export AGENTICMODE_TEST_MENU_RESPONSE="$helper_response"
export AGENTICMODE_TEST_MENU_REQUEST="$helper_request"
printf 'AC Power\n' > "$test_root/power"
printf '78\n' > "$test_root/battery"
printf 'none\n' > "$test_root/fail-value"
printf '0\n' > "$test_root/fail-count"
: > "$test_root/sudo.log"; : > "$test_root/watchdog.log"

assert_contains() { grep -Fq -- "$1" "$2" || { printf 'Missing %s in %s\n' "$1" "$2" >&2; exit 1; }; }
assert_equals() { [ "$1" = "$2" ] || { printf 'Expected %s, got %s\n' "$1" "$2" >&2; exit 1; }; }
assert_no_power_change() { ! grep -Fq -- '-a disablesleep' "$pmset_log" || { printf 'Unexpected power mutation:\n' >&2; cat "$pmset_log" >&2; exit 1; }; }

run_menu_pty() {
  TERM=xterm-256color AGENTICMODE_EXPECT_BIN="$repo_dir/bin/agenticmode" /usr/bin/expect <<'EXPECT_MENU' >/dev/null 2>&1
set timeout 15
spawn -noecho $env(AGENTICMODE_EXPECT_BIN)
expect eof
set status [lindex [wait] 3]
exit $status
EXPECT_MENU
}

printf 'Test: cancel is read-only and request is bounded protocol\n'
cat > "$helper_response" <<'CHOICE'
agenticmode-choice-v1
generation|1
action|cancel
end
CHOICE
run_menu_pty
assert_no_power_change
assert_contains 'agenticmode-menu-v1' "$helper_request"
assert_contains 'generation|1' "$helper_request"
assert_contains 'power|adapter|78' "$helper_request"
assert_contains 'defaults|current-all|0|0|5' "$helper_request"
assert_contains 'end' "$helper_request"

printf 'Test: malformed response fails without power changes\n'
: > "$pmset_log"
printf 'agenticmode-choice-v1\ngeneration|1\naction|start\ncompletion|manual\nunknown|field\nend\n' > "$helper_response"
if run_menu_pty; then printf 'Malformed launcher response succeeded\n' >&2; exit 1; fi
assert_no_power_change

printf 'Test: redirected zero-argument invocation fails read-only\n'
: > "$pmset_log"
if "$repo_dir/bin/agenticmode" </dev/null > "$test_root/redirected.log" 2>&1; then printf 'Redirected zero-argument invocation succeeded\n' >&2; exit 1; fi
assert_no_power_change

printf 'Test: start response cannot omit safeguard fields\n'
: > "$pmset_log"
printf 'agenticmode-choice-v1\ngeneration|1\naction|start\ncompletion|manual\nend\n' > "$helper_response"
if run_menu_pty; then printf 'Incomplete start response succeeded\n' >&2; exit 1; fi
assert_no_power_change

printf 'Test: missing zero-argument helper fails read-only\n'
: > "$pmset_log"
if AGENTICMODE_UI_BIN="$test_root/missing-ui" run_menu_pty; then printf 'Missing helper fell through to awake mode\n' >&2; exit 1; fi
assert_no_power_change

printf 'Test: helper version mismatch fails without power changes\n'
: > "$pmset_log"
cp "$helper" "$test_root/fake-ui-mismatch"
sed 's/agenticmode-ui 1.4.0/agenticmode-ui 9.9.9/' "$test_root/fake-ui-mismatch" > "$test_root/fake-ui-mismatch.next"
mv "$test_root/fake-ui-mismatch.next" "$test_root/fake-ui-mismatch"
chmod 755 "$test_root/fake-ui-mismatch"
AGENTICMODE_UI_BIN="$test_root/fake-ui-mismatch" run_menu_pty && { printf 'Mismatched helper succeeded\n' >&2; exit 1; }
assert_no_power_change

printf 'Test: read-only command dispatch\n'
cat > "$helper_response" <<'CHOICE'
agenticmode-choice-v1
generation|1
action|help
end
CHOICE
run_menu_pty
assert_no_power_change

printf 'Test: selected exact process starts only after validated choice\n'
/bin/sleep 30 &
target_pid=$!
cat > "$helper_response" <<'CHOICE'
agenticmode-choice-v1
generation|1
action|start
completion|current-selected
target|t0001
timeout-seconds|2
min-battery|0
end
CHOICE
set +e
TERM=xterm-256color AGENTICMODE_EXPECT_BIN="$repo_dir/bin/agenticmode" AGENTICMODE_EXPECT_PID="$target_pid" /usr/bin/expect <<'EXPECT_SELECTED' >/dev/null 2>&1
set timeout 15
spawn -noecho $env(AGENTICMODE_EXPECT_BIN) menu --no-codex --no-processes --no-activities --pid $env(AGENTICMODE_EXPECT_PID)
expect eof
set status [lindex [wait] 3]
exit $status
EXPECT_SELECTED
selected_status=$?
set -e
[ "$selected_status" -eq 75 ] || { printf 'Expected selected timeout 75, got %s\n' "$selected_status" >&2; exit 1; }
selected_pmset_state=$(cat "$pmset_state")
[ "$selected_pmset_state" = "0" ] || { printf 'Selected mode left pmset state <%s>\n' "$selected_pmset_state" >&2; cat "$pmset_log" >&2; cat "$test_root/watchdog.log" >&2; exit 1; }
assert_contains 'candidate|t0001|process|' "$helper_request"
assert_contains '-a disablesleep 1' "$pmset_log"
assert_contains '-a disablesleep 0' "$pmset_log"
kill -TERM "$target_pid" 2>/dev/null || true
wait "$target_pid" 2>/dev/null || true
target_pid=""

printf 'Test: stale battery choice is rejected before power changes\n'
: > "$pmset_log"
printf 'Battery Power\n' > "$test_root/power"
printf '20\n' > "$test_root/battery"
cat > "$helper_response" <<'CHOICE'
agenticmode-choice-v1
generation|1
action|start
completion|manual
timeout-seconds|0
min-battery|25
end
CHOICE
if run_menu_pty; then printf 'Unsafe battery choice succeeded\n' >&2; exit 1; fi
assert_no_power_change

printf 'Test: terminating launcher parent restores termios and stops helper\n'
block_ready="$test_root/block-ready"
block_pid_file="$test_root/block-pid"
mkdir -p "$test_root/menu-tmp"
set +e
TERM=xterm-256color \
  TMPDIR="$test_root/menu-tmp" \
  AGENTICMODE_EXPECT_BIN="$repo_dir/bin/agenticmode" \
  AGENTICMODE_TEST_MENU_BLOCK_READY="$block_ready" \
  AGENTICMODE_TEST_MENU_BLOCK_PID="$block_pid_file" \
  /usr/bin/expect <<'EXPECT_MENU_TERM' > "$test_root/menu-term.expect.log" 2>&1
set timeout 20
spawn -noecho /bin/bash --noprofile --norc +H
set terminal $spawn_out(slave,name)
exec /bin/stty -isig intr undef < $terminal
set before [string trim [exec /bin/stty -g < $terminal]]
send -- "/bin/bash -c 'echo MENU_PID:\$\$; exec \"\$1\" menu' launcher \"$env(AGENTICMODE_EXPECT_BIN)\"; echo MENU_STATUS:\$?\r"
expect {
  -re {MENU_PID:([0-9]+)} { set menu_pid $expect_out(1,string) }
  timeout { exit 5 }
}
for {set attempt 0} {$attempt < 100} {incr attempt} {
  if {[file exists $env(AGENTICMODE_TEST_MENU_BLOCK_READY)]} { break }
  after 50
}
if {![file exists $env(AGENTICMODE_TEST_MENU_BLOCK_READY)]} { exit 2 }
exec kill -TERM $menu_pid
expect {
  "MENU_STATUS:143" {}
  timeout { exit 3 }
}
expect {
  -exact "bash-3.2$ " {}
  timeout { exit 6 }
}
set after [string trim [exec /bin/stty -g < $terminal]]
if {$after ne $before} { exit 4 }
exec /bin/stty echo < $terminal
send -- "exit\r"
expect eof
exit 0
EXPECT_MENU_TERM
menu_term_status=$?
set -e
[ "$menu_term_status" -eq 0 ] || { cat "$test_root/menu-term.expect.log" >&2; exit 1; }
blocked_helper_pid=$(cat "$block_pid_file")
if kill -0 "$blocked_helper_pid" 2>/dev/null; then printf 'Launcher helper survived parent termination\n' >&2; exit 1; fi
if find "$test_root/menu-tmp" -mindepth 1 -print -quit | grep -q .; then printf 'Launcher temporary files survived parent termination\n' >&2; exit 1; fi
assert_no_power_change

printf 'Test: real launcher restores exact inherited termios after Ctrl+C\n'
real_helper="$test_root/agenticmode-ui"
(
  cd "$repo_dir"
  GOWORK=off GOFLAGS='-mod=readonly' go build -trimpath -buildvcs=false -o "$real_helper" ./cmd/agenticmode-ui
)
set +e
TERM=xterm-256color \
  AGENTICMODE_EXPECT_BIN="$repo_dir/bin/agenticmode" \
  AGENTICMODE_UI_BIN="$real_helper" \
  /usr/bin/expect <<'EXPECT_REAL_HELPER' > "$test_root/real-helper.expect.log" 2>&1
set timeout 20
spawn -noecho /bin/bash --noprofile --norc
set terminal $spawn_out(slave,name)
exec /bin/stty -isig intr undef < $terminal
set before [string trim [exec /bin/stty -g < $terminal]]
send -- "$env(AGENTICMODE_EXPECT_BIN); echo MENU_STATUS:\$?\r"
expect {
  -exact "\033\[?1049h" {}
  timeout { exit 2 }
}
after 2500
send -- "\003"
expect {
  "MENU_STATUS:0" {}
  timeout { exit 5 }
}
set after [string trim [exec /bin/stty -g < $terminal]]
if {$after ne $before} { exit 3 }
exec /bin/stty echo < $terminal
send -- "exit\r"
expect eof
exit 0
EXPECT_REAL_HELPER
real_helper_status=$?
set -e
[ "$real_helper_status" -eq 0 ] || { cat "$test_root/real-helper.expect.log" >&2; exit 1; }

printf 'All menu tests passed.\n'
