#!/bin/bash

set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
source_file="$script_dir/bin/agenticmode"
removed=0

for target in /opt/homebrew/bin/agenticmode /usr/local/bin/agenticmode "$HOME/.local/bin/agenticmode"; do
  if [ -L "$target" ] && [ "$(readlink "$target")" = "$source_file" ]; then
    rm "$target"
    printf 'Removed %s\n' "$target"
    removed=1
  fi
done

if [ "$removed" -eq 0 ]; then
  printf 'No agenticmode symlink for this checkout was found.\n'
fi
