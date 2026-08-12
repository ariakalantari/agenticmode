#!/bin/bash

set -eu

repository="ariakalantari/agenticmode"
curl_bin="${AGENTICMODE_CURL_BIN:-/usr/bin/curl}"
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
source_file="$script_dir/bin/agenticmode"
helper_source="$script_dir/libexec/agenticmode-watchdog"
ui_source="$script_dir/libexec/agenticmode-ui"
ui_build_script="$script_dir/scripts/build-ui.sh"
helper_target=/Library/PrivilegedHelperTools/com.ariakalantari.agenticmode.watchdog
remote_marker="$script_dir/.agenticmode-remote-install"
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

select_install_prefix() {
  local selected
  if [ -n "${PREFIX:-}" ]; then
    selected="$PREFIX"
  elif [ -d /opt/homebrew/bin ] && [ -w /opt/homebrew/bin ]; then
    selected=/opt/homebrew
  elif [ -d /usr/local/bin ] && [ -w /usr/local/bin ]; then
    selected=/usr/local
  else
    selected="$HOME/.local"
  fi
  case "$selected" in
    /*) ;;
    *) printf 'install.sh: PREFIX must be an absolute path\n' >&2; return 1 ;;
  esac
  case "$selected" in
    /|"$HOME") printf 'install.sh: refusing unsafe install prefix: %s\n' "$selected" >&2; return 1 ;;
  esac
  [ ! -L "$selected" ] || { printf 'install.sh: refusing symlinked install prefix: %s\n' "$selected" >&2; return 1; }
  printf '%s\n' "$selected"
}

bootstrap_remote_install() {
  install_ref="${AGENTICMODE_INSTALL_REF:-main}"
  install_root="${AGENTICMODE_INSTALL_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/agenticmode}"
  curl_bin="${AGENTICMODE_CURL_BIN:-/usr/bin/curl}"
  install_prefix=$(select_install_prefix) || exit 1
  if [ -n "${AGENTICMODE_INSTALL_REF+x}" ]; then
    install_channel="pinned:$install_ref"
  else
    install_channel="stable"
  fi

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

  temporary=$(mktemp -d "${TMPDIR:-/tmp}/agenticmode-install.XXXXXX") || exit 1
  trap 'rm -rf "$temporary"' EXIT INT TERM HUP
  mkdir -p "$temporary/bin" "$temporary/libexec"

  use_release_archive=0
  if [ -z "${AGENTICMODE_INSTALL_BASE_URL:-}" ]; then
    case "$install_channel" in
      stable) release_base="${AGENTICMODE_INSTALL_RELEASE_BASE_URL:-https://github.com/$repository/releases/latest/download}"; use_release_archive=1 ;;
      pinned:v[0-9]*.[0-9]*.[0-9]*) release_base="${AGENTICMODE_INSTALL_RELEASE_BASE_URL:-https://github.com/$repository/releases/download/$install_ref}"; use_release_archive=1 ;;
    esac
  fi
  if [ "$use_release_archive" -eq 1 ]; then
    release_base=${release_base%/}
    archive="$temporary/agenticmode.tar.gz"
    checksum_file="$temporary/agenticmode.tar.gz.sha256"
    extract_root="$temporary/extract"
    listing="$temporary/archive.list"
    mkdir -p "$extract_root"
    "$curl_bin" -fsSL "$release_base/agenticmode.tar.gz.sha256" -o "$checksum_file" || {
      printf 'install.sh: could not download the stable release checksum\n' >&2; exit 1;
    }
    "$curl_bin" -fsSL "$release_base/agenticmode.tar.gz" -o "$archive" || {
      printf 'install.sh: could not download the stable release archive\n' >&2; exit 1;
    }
    checksum=$(/usr/bin/awk 'NR == 1 { print $1 } END { if (NR != 1 || NF != 2 || $2 != "agenticmode.tar.gz") exit 1 }' "$checksum_file") || {
      printf 'install.sh: the stable release checksum file is malformed\n' >&2; exit 1;
    }
    [ "${#checksum}" -eq 64 ] || { printf 'install.sh: the stable release checksum is malformed\n' >&2; exit 1; }
    case "$checksum" in *[!A-Fa-f0-9]*) printf 'install.sh: the stable release checksum is malformed\n' >&2; exit 1 ;; esac
    actual_checksum=$(/usr/bin/shasum -a 256 "$archive" | /usr/bin/awk '{ print $1 }')
    [ "$actual_checksum" = "$checksum" ] || { printf 'install.sh: the stable release checksum did not match\n' >&2; exit 1; }
    /usr/bin/tar -tzf "$archive" > "$listing" || { printf 'install.sh: the stable release archive could not be inspected\n' >&2; exit 1; }
    while IFS= read -r entry; do
      case "$entry" in
        agenticmode|agenticmode/|agenticmode/bin|agenticmode/bin/|agenticmode/libexec|agenticmode/libexec/|\
        agenticmode/install.sh|agenticmode/uninstall.sh|agenticmode/config.example|\
        agenticmode/bin/agenticmode|agenticmode/libexec/agenticmode-watchdog) ;;
        *) printf 'install.sh: the stable release archive contains an unexpected path: %s\n' "$entry" >&2; exit 1 ;;
      esac
    done < "$listing"
    /usr/bin/tar -xzf "$archive" -C "$extract_root" || { printf 'install.sh: the stable release archive could not be extracted\n' >&2; exit 1; }
    for relative in install.sh uninstall.sh config.example bin/agenticmode libexec/agenticmode-watchdog; do
      [ -f "$extract_root/agenticmode/$relative" ] && [ ! -L "$extract_root/agenticmode/$relative" ] || {
        printf 'install.sh: the stable release is missing a safe %s\n' "$relative" >&2; exit 1;
      }
    done
    [ -x "$extract_root/agenticmode/bin/agenticmode" ] && [ -x "$extract_root/agenticmode/libexec/agenticmode-watchdog" ] || {
      printf 'install.sh: the stable release contains a non-executable runtime component\n' >&2; exit 1;
    }
    /bin/cp "$extract_root/agenticmode/install.sh" "$temporary/install.sh"
    /bin/cp "$extract_root/agenticmode/uninstall.sh" "$temporary/uninstall.sh"
    /bin/cp "$extract_root/agenticmode/config.example" "$temporary/config.example"
    /bin/cp "$extract_root/agenticmode/bin/agenticmode" "$temporary/bin/agenticmode"
    /bin/cp "$extract_root/agenticmode/libexec/agenticmode-watchdog" "$temporary/libexec/agenticmode-watchdog"
  else
    download_base="${AGENTICMODE_INSTALL_BASE_URL:-https://raw.githubusercontent.com/$repository/$install_ref}"
    download_base=${download_base%/}
    for relative in install.sh uninstall.sh config.example bin/agenticmode libexec/agenticmode-watchdog; do
      "$curl_bin" -fsSL "$download_base/$relative" -o "$temporary/$relative" || {
        printf 'install.sh: could not download %s from %s\n' "$relative" "$download_base" >&2
        exit 1
      }
    done
  fi

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
  for relative in install.sh uninstall.sh config.example bin/agenticmode libexec/agenticmode-watchdog libexec/agenticmode-ui .agenticmode-remote-install; do
    [ ! -L "$install_root/$relative" ] || {
      printf 'install.sh: refusing to replace symlink: %s\n' "$install_root/$relative" >&2
      exit 1
    }
  done

  printf 'agenticmode-remote-install:v2\n%s\n%s\n%s\n' "$install_channel" "$install_root" "$install_prefix" > "$temporary/.agenticmode-remote-install"
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
[ ! -L "$ui_source" ] || {
  printf 'install.sh: refusing unsafe UI companion: %s\n' "$ui_source" >&2
  exit 1
}
if { [ "${AGENTICMODE_TESTING:-0}" != "1" ] || [ "${AGENTICMODE_TEST_BUILD_UI:-0}" = "1" ]; } && \
  [ -f "$script_dir/go.mod" ] && [ -d "$script_dir/cmd/agenticmode-ui" ] && \
  [ -x "$ui_build_script" ] && command -v go >/dev/null 2>&1; then
  "$ui_build_script" "$ui_source"
fi
ui_compatible=0
if [ -f "$ui_source" ] && [ -x "$ui_source" ] && [ ! -L "$ui_source" ]; then
  cli_version_output=$("$source_file" --version 2>/dev/null || true)
  case "$cli_version_output" in 'agenticmode '*) cli_version=${cli_version_output#agenticmode } ;; *) cli_version="" ;; esac
  if [ -n "$cli_version" ] && [ "$("$ui_source" --protocol-version 2>/dev/null || true)" = "1" ] && \
    [ "$("$ui_source" --version 2>/dev/null || true)" = "agenticmode-ui $cli_version" ]; then
    ui_compatible=1
  fi
fi
if [ "$ui_compatible" -eq 0 ] && { [ -n "${AGENTICMODE_UI_RELEASE_BASE_URL:-}" ] || \
  [ "${AGENTICMODE_TESTING:-0}" != "1" ] || [ -n "${AGENTICMODE_TEST_RELEASE_BASE_URL:-}" ]; }; then
  cli_version_output=$("$source_file" --version 2>/dev/null) || { printf 'install.sh: the CLI cannot report its version\n' >&2; exit 1; }
  case "$cli_version_output" in 'agenticmode '*) cli_version=${cli_version_output#agenticmode } ;; *) printf 'install.sh: the CLI reported an invalid version\n' >&2; exit 1 ;; esac
  if [ -n "${AGENTICMODE_UI_RELEASE_BASE_URL:-}" ]; then
    ui_release_base=${AGENTICMODE_UI_RELEASE_BASE_URL%/}
  elif [ "${AGENTICMODE_TESTING:-0}" = "1" ] && [ -n "${AGENTICMODE_TEST_RELEASE_BASE_URL:-}" ]; then
    ui_release_base="${AGENTICMODE_TEST_RELEASE_BASE_URL%/}/latest/download"
  else
    ui_release_base="https://github.com/$repository/releases/download/v$cli_version"
  fi
  ui_temporary=$(mktemp -d "${TMPDIR:-/tmp}/agenticmode-ui-install.XXXXXX") || exit 1
  trap 'rm -rf "$ui_temporary"' EXIT INT TERM HUP
  "$curl_bin" -fsSL "$ui_release_base/agenticmode-ui.sha256" -o "$ui_temporary/agenticmode-ui.sha256" || { printf 'install.sh: could not download the launcher checksum\n' >&2; exit 1; }
  "$curl_bin" -fsSL "$ui_release_base/agenticmode-ui" -o "$ui_temporary/agenticmode-ui" || { printf 'install.sh: could not download the launcher\n' >&2; exit 1; }
  ui_checksum=$(/usr/bin/awk 'NR == 1 { print $1 } END { if (NR != 1 || NF != 2 || $2 != "agenticmode-ui") exit 1 }' "$ui_temporary/agenticmode-ui.sha256") || { printf 'install.sh: the launcher checksum file is malformed\n' >&2; exit 1; }
  [ "${#ui_checksum}" -eq 64 ] || { printf 'install.sh: the launcher checksum is malformed\n' >&2; exit 1; }
  case "$ui_checksum" in *[!A-Fa-f0-9]*) printf 'install.sh: the launcher checksum is malformed\n' >&2; exit 1 ;; esac
  ui_actual_checksum=$(/usr/bin/shasum -a 256 "$ui_temporary/agenticmode-ui" | /usr/bin/awk '{ print $1 }')
  [ "$ui_actual_checksum" = "$ui_checksum" ] || { printf 'install.sh: the launcher checksum did not match\n' >&2; exit 1; }
  chmod 755 "$ui_temporary/agenticmode-ui"
  [ "$("$ui_temporary/agenticmode-ui" --protocol-version 2>/dev/null)" = "1" ] && \
    [ "$("$ui_temporary/agenticmode-ui" --version 2>/dev/null)" = "agenticmode-ui $cli_version" ] || { printf 'install.sh: the launcher is incompatible with the CLI\n' >&2; exit 1; }
  ui_staging="${ui_source}.install.$$"
  [ ! -e "$ui_staging" ] && [ ! -L "$ui_staging" ] || { printf 'install.sh: refusing existing launcher staging path\n' >&2; exit 1; }
  /usr/bin/install -m 755 "$ui_temporary/agenticmode-ui" "$ui_staging"
  /bin/mv -f "$ui_staging" "$ui_source"
  trap - EXIT INT TERM HUP
  rm -rf "$ui_temporary"
  ui_compatible=1
fi
if [ -e "$ui_source" ] || [ -L "$ui_source" ]; then
  [ -f "$ui_source" ] && [ -x "$ui_source" ] && [ ! -L "$ui_source" ] || {
    printf 'install.sh: refusing unsafe UI companion: %s\n' "$ui_source" >&2
    exit 1
  }
fi

install_prefix=$(select_install_prefix) || exit 1
install_dir="$install_prefix/bin"

mkdir -p "$install_dir"
target="$install_dir/agenticmode"
alias_target="$install_dir/am"

for command_target in "$target" "$alias_target"; do
  if [ -e "$command_target" ] && [ ! -L "$command_target" ]; then
    printf 'install.sh: refusing to replace non-symlink %s\n' "$command_target" >&2
    exit 1
  fi
  if [ -L "$command_target" ] && [ "$(readlink "$command_target")" != "$source_file" ] && [ "$force" -ne 1 ]; then
    printf 'install.sh: refusing to replace a symlink owned by another install: %s\n' "$command_target" >&2
    printf 'Re-run with --force only if you intend to replace it.\n' >&2
    exit 1
  fi
done

managed_marker=0
if [ -e "$remote_marker" ] || [ -L "$remote_marker" ]; then
  [ -f "$remote_marker" ] && [ ! -L "$remote_marker" ] || {
    printf 'install.sh: refusing unsafe managed install metadata\n' >&2
    exit 1
  }
  marker_header=$(/usr/bin/sed -n '1p' "$remote_marker" 2>/dev/null || true)
  case "$marker_header" in
    agenticmode-remote-install:v2)
      marker_channel=$(/usr/bin/sed -n '2p' "$remote_marker" 2>/dev/null || true)
      marker_root=$(/usr/bin/sed -n '3p' "$remote_marker" 2>/dev/null || true)
      ;;
    agenticmode-remote-install:*)
      marker_ref=${marker_header#agenticmode-remote-install:}
      case "$marker_ref" in main) marker_channel=stable ;; *) marker_channel="pinned:$marker_ref" ;; esac
      marker_root=$(/usr/bin/sed -n '2p' "$remote_marker" 2>/dev/null || true)
      ;;
    *)
      printf 'install.sh: refusing malformed managed install metadata\n' >&2
      exit 1
      ;;
  esac
  [ "$marker_root" = "$script_dir" ] || {
    printf 'install.sh: managed install marker does not match %s\n' "$script_dir" >&2
    exit 1
  }
  case "$marker_channel" in
    stable) ;;
    pinned:*)
      marker_ref=${marker_channel#pinned:}
      case "$marker_ref" in ''|*..*|*[!A-Za-z0-9._-]*) printf 'install.sh: invalid managed install channel\n' >&2; exit 1 ;; esac
      ;;
    *) printf 'install.sh: invalid managed install channel\n' >&2; exit 1 ;;
  esac
  managed_marker=1
fi

chmod 755 "$source_file"
chmod 755 "$helper_source"
[ ! -f "$ui_source" ] || chmod 755 "$ui_source"

if [ "${AGENTICMODE_TESTING:-0}" != "1" ]; then
  printf 'Installing the root-owned safety watchdog. macOS may ask for your password.\n'
  /usr/bin/sudo -v
  /usr/bin/sudo /usr/bin/install -o root -g wheel -m 755 "$helper_source" "$helper_target"
fi

ln -sfn "$source_file" "$target"
ln -sfn "$source_file" "$alias_target"

if [ "$managed_marker" -eq 1 ]; then
  marker_temporary="$remote_marker.$$"
  printf 'agenticmode-remote-install:v2\n%s\n%s\n%s\n' "$marker_channel" "$script_dir" "$install_prefix" > "$marker_temporary"
  chmod 600 "$marker_temporary"
  mv "$marker_temporary" "$remote_marker"
fi

printf 'Installed agenticmode at %s\n' "$target"
case ":$PATH:" in
  *":$install_dir:"*) ;;
  *)
    printf 'Add this directory to PATH, then open a new terminal:\n'
    printf '  export PATH="%s:$PATH"\n' "$install_dir"
    ;;
esac

printf 'Run: agenticmode --help (or am --help)\n'
