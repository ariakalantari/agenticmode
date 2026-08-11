#!/bin/bash

set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
source_file="$script_dir/bin/agenticmode"
helper_target=/Library/PrivilegedHelperTools/com.ariakalantari.agenticmode.watchdog
removed=0
status_output=""
status_code=0

if [ -x "$source_file" ]; then
  status_output=$("$source_file" status 2>&1) || status_code=$?
  case "$status_output" in
    *'SleepDisabled: 1'*|*'Controller: active'*) "$source_file" off ;;
    *'SleepDisabled: 0'*) ;;
    *)
      printf 'uninstall.sh: could not verify that sleep is safe; refusing to uninstall\n' >&2
      printf '%s\n' "$status_output" >&2
      [ "$status_code" -ne 0 ] || status_code=1
      exit "$status_code"
      ;;
  esac
fi

if [ -n "${PREFIX:-}" ]; then
  targets=("$PREFIX/bin/agenticmode")
else
  targets=(/opt/homebrew/bin/agenticmode /usr/local/bin/agenticmode "$HOME/.local/bin/agenticmode")
fi

for target in "${targets[@]}"; do
  if [ -L "$target" ] && [ "$(readlink "$target")" = "$source_file" ]; then
    rm "$target"
    printf 'Removed %s\n' "$target"
    removed=1
  fi
done

if [ "$removed" -eq 0 ]; then
  printf 'No agenticmode symlink for this checkout was found.\n'
fi

if [ "${AGENTICMODE_TESTING:-0}" != "1" ] && [ -f "$helper_target" ] && [ ! -L "$helper_target" ]; then
  printf 'Removing the root-owned safety watchdog. macOS may ask for your password.\n'
  /usr/bin/sudo /bin/rm "$helper_target"
  printf 'Removed %s\n' "$helper_target"
fi
