#!/bin/bash

set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
source_file="$script_dir/bin/agenticmode"
helper_source="$script_dir/libexec/agenticmode-watchdog"
helper_target=/Library/PrivilegedHelperTools/com.ariakalantari.agenticmode.watchdog
force=0

case "${1:-}" in
  '') ;;
  --force) force=1 ;;
  -h|--help)
    printf 'Usage: [PREFIX=/path] ./install.sh [--force]\n'
    exit 0
    ;;
  *)
    printf 'install.sh: unknown argument: %s\n' "$1" >&2
    exit 1
    ;;
esac

if [ ! -f "$source_file" ]; then
  printf 'install.sh: %s was not found\n' "$source_file" >&2
  exit 1
fi
if [ ! -f "$helper_source" ]; then
  printf 'install.sh: %s was not found\n' "$helper_source" >&2
  exit 1
fi

if [ -n "${PREFIX:-}" ]; then
  install_dir="$PREFIX/bin"
elif [ -d /opt/homebrew/bin ] && [ -w /opt/homebrew/bin ]; then
  install_dir=/opt/homebrew/bin
elif [ -d /usr/local/bin ] && [ -w /usr/local/bin ]; then
  install_dir=/usr/local/bin
else
  install_dir="$HOME/.local/bin"
fi

mkdir -p "$install_dir"
target="$install_dir/agenticmode"

if [ -e "$target" ] && [ ! -L "$target" ]; then
  printf 'install.sh: refusing to replace non-symlink %s\n' "$target" >&2
  exit 1
fi
if [ -L "$target" ] && [ "$(readlink "$target")" != "$source_file" ] && [ "$force" -ne 1 ]; then
  printf 'install.sh: refusing to replace a symlink owned by another install: %s\n' "$target" >&2
  printf 'Re-run with --force only if you intend to replace it.\n' >&2
  exit 1
fi

chmod 755 "$source_file"
chmod 755 "$helper_source"

if [ "${AGENTICMODE_TESTING:-0}" != "1" ]; then
  printf 'Installing the root-owned safety watchdog. macOS may ask for your password.\n'
  /usr/bin/sudo -v
  /usr/bin/sudo /usr/bin/install -o root -g wheel -m 755 "$helper_source" "$helper_target"
fi

ln -sfn "$source_file" "$target"

printf 'Installed agenticmode at %s\n' "$target"
case ":$PATH:" in
  *":$install_dir:"*) ;;
  *)
    printf 'Add this directory to PATH, then open a new terminal:\n'
    printf '  export PATH="%s:$PATH"\n' "$install_dir"
    ;;
esac

printf 'Run: agenticmode --help\n'
