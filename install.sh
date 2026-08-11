#!/bin/bash

set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
source_file="$script_dir/bin/agenticmode"

if [ ! -f "$source_file" ]; then
  printf 'install.sh: %s was not found\n' "$source_file" >&2
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

ln -sfn "$source_file" "$target"
chmod 755 "$source_file"

printf 'Installed agenticmode at %s\n' "$target"
case ":$PATH:" in
  *":$install_dir:"*) ;;
  *)
    printf 'Add this directory to PATH, then open a new terminal:\n'
    printf '  export PATH="%s:$PATH"\n' "$install_dir"
    ;;
esac

printf 'Run: agenticmode --help\n'
