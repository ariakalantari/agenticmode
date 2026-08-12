#!/bin/bash

set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
source_file="$script_dir/bin/agenticmode"
helper_target=/Library/PrivilegedHelperTools/com.ariakalantari.agenticmode.watchdog
remote_marker="$script_dir/.agenticmode-remote-install"
removed=0
status_output=""
status_code=0

if [ -x "$source_file" ]; then
  status_output=$("$source_file" status --machine 2>&1) || status_code=$?
  case "$status_output" in
    *'sleep_disabled=1'*|*'controller=active'*) "$source_file" off ;;
    *'sleep_disabled=0'*'controller=inactive'*) ;;
    *)
      printf 'uninstall.sh: could not verify that sleep is safe; refusing to uninstall\n' >&2
      printf '%s\n' "$status_output" >&2
      [ "$status_code" -ne 0 ] || status_code=1
      exit "$status_code"
      ;;
  esac
fi

if [ -n "${PREFIX:-}" ]; then
  targets=("$PREFIX/bin/agenticmode" "$PREFIX/bin/am")
else
  targets=(
    /opt/homebrew/bin/agenticmode /opt/homebrew/bin/am
    /usr/local/bin/agenticmode /usr/local/bin/am
    "$HOME/.local/bin/agenticmode" "$HOME/.local/bin/am"
  )
fi

for target in "${targets[@]}"; do
  if [ -L "$target" ] && [ "$(readlink "$target")" = "$source_file" ]; then
    rm "$target"
    printf 'Removed %s\n' "$target"
    removed=1
  fi
done

if [ "$removed" -eq 0 ]; then
  printf 'No agenticmode or am symlink for this checkout was found.\n'
fi

if [ "${AGENTICMODE_TESTING:-0}" != "1" ] && [ -f "$helper_target" ] && [ ! -L "$helper_target" ]; then
  printf 'Removing the root-owned safety watchdog. macOS may ask for your password.\n'
  /usr/bin/sudo /bin/rm "$helper_target"
  printf 'Removed %s\n' "$helper_target"
fi

if [ -f "$remote_marker" ] && [ ! -L "$remote_marker" ]; then
  marker_header=$(/usr/bin/sed -n '1p' "$remote_marker" 2>/dev/null || true)
  case "$marker_header" in
    agenticmode-remote-install:v2)
      marker_root=$(/usr/bin/sed -n '3p' "$remote_marker" 2>/dev/null || true)
      ;;
    agenticmode-remote-install:*)
      marker_root=$(/usr/bin/sed -n '2p' "$remote_marker" 2>/dev/null || true)
      ;;
  esac
  case "$marker_header" in
    agenticmode-remote-install:*)
      [ "$marker_root" = "$script_dir" ] || {
        printf 'uninstall.sh: managed install marker does not match %s\n' "$script_dir" >&2
        exit 1
      }
      case "$script_dir" in
        /|"$HOME")
          printf 'uninstall.sh: refusing unsafe managed install directory: %s\n' "$script_dir" >&2
          exit 1
          ;;
      esac
      rm -f "$script_dir/bin/agenticmode" "$script_dir/libexec/agenticmode-watchdog" \
        "$script_dir/libexec/agenticmode-ui" \
        "$script_dir/config.example" "$remote_marker" "$script_dir/install.sh" "$script_dir/uninstall.sh"
      rmdir "$script_dir/bin" "$script_dir/libexec" "$script_dir" 2>/dev/null || true
      printf 'Removed managed install at %s\n' "$script_dir"
      ;;
  esac
fi
