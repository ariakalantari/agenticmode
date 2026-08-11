#!/bin/bash

set -eu

repository="ariakalantari/agenticmode"
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

bootstrap_remote_install() {
  install_ref="${AGENTICMODE_INSTALL_REF:-main}"
  install_root="${AGENTICMODE_INSTALL_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/agenticmode}"
  curl_bin="${AGENTICMODE_CURL_BIN:-/usr/bin/curl}"

  case "$install_ref" in
    ''|*..*|*[!A-Za-z0-9._-]*)
      printf 'install.sh: invalid AGENTICMODE_INSTALL_REF: %s\n' "$install_ref" >&2
      exit 1
      ;;
  esac
  case "$install_root" in
    /*) ;;
    *)
      printf 'install.sh: AGENTICMODE_INSTALL_DIR must be an absolute path\n' >&2
      exit 1
      ;;
  esac
  case "$install_root" in
    /|"$HOME")
      printf 'install.sh: refusing unsafe AGENTICMODE_INSTALL_DIR: %s\n' "$install_root" >&2
      exit 1
      ;;
  esac
  [ ! -L "$install_root" ] || {
    printf 'install.sh: refusing symlinked install directory: %s\n' "$install_root" >&2
    exit 1
  }
  [ -x "$curl_bin" ] || {
    printf 'install.sh: curl was not found at %s\n' "$curl_bin" >&2
    exit 1
  }

  download_base="${AGENTICMODE_INSTALL_BASE_URL:-https://raw.githubusercontent.com/$repository/$install_ref}"
  download_base=${download_base%/}
  temporary=$(mktemp -d "${TMPDIR:-/tmp}/agenticmode-install.XXXXXX") || exit 1
  trap 'rm -rf "$temporary"' EXIT INT TERM HUP
  mkdir -p "$temporary/bin" "$temporary/libexec"

  for relative in install.sh uninstall.sh config.example bin/agenticmode libexec/agenticmode-watchdog; do
    "$curl_bin" -fsSL "$download_base/$relative" -o "$temporary/$relative" || {
      printf 'install.sh: could not download %s from %s\n' "$relative" "$download_base" >&2
      exit 1
    }
  done

  /bin/bash -n "$temporary/install.sh" "$temporary/uninstall.sh" \
    "$temporary/bin/agenticmode" "$temporary/libexec/agenticmode-watchdog" || {
    printf 'install.sh: downloaded files failed shell syntax validation\n' >&2
    exit 1
  }

  for directory in "$install_root/bin" "$install_root/libexec"; do
    [ ! -L "$directory" ] || {
      printf 'install.sh: refusing symlinked install directory: %s\n' "$directory" >&2
      exit 1
    }
  done
  mkdir -p "$install_root/bin" "$install_root/libexec"
  install_root=$(CDPATH= cd -- "$install_root" && pwd)
  for relative in install.sh uninstall.sh config.example bin/agenticmode libexec/agenticmode-watchdog .agenticmode-remote-install; do
    [ ! -L "$install_root/$relative" ] || {
      printf 'install.sh: refusing to replace symlink: %s\n' "$install_root/$relative" >&2
      exit 1
    }
  done

  printf 'agenticmode-remote-install:%s\n%s\n' "$install_ref" "$install_root" > "$temporary/.agenticmode-remote-install"
  /usr/bin/install -m 755 "$temporary/install.sh" "$install_root/install.sh"
  /usr/bin/install -m 755 "$temporary/uninstall.sh" "$install_root/uninstall.sh"
  /usr/bin/install -m 755 "$temporary/bin/agenticmode" "$install_root/bin/agenticmode"
  /usr/bin/install -m 755 "$temporary/libexec/agenticmode-watchdog" "$install_root/libexec/agenticmode-watchdog"
  /usr/bin/install -m 644 "$temporary/config.example" "$install_root/config.example"
  /usr/bin/install -m 600 "$temporary/.agenticmode-remote-install" "$install_root/.agenticmode-remote-install"

  trap - EXIT INT TERM HUP
  rm -rf "$temporary"
  printf 'Downloaded agenticmode (%s) to %s\n' "$install_ref" "$install_root"
  "$install_root/install.sh" "$@"
  exit $?
}

if [ ! -f "$source_file" ] && [ ! -f "$helper_source" ]; then
  bootstrap_remote_install "$@"
fi

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
