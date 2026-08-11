#!/bin/bash

set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tag="${1:-}"
output_dir="${2:-$repo_dir/dist}"

case "$tag" in
  v[0-9]*.[0-9]*.[0-9]*) ;;
  *) printf 'Usage: %s vMAJOR.MINOR.PATCH [OUTPUT_DIR]\n' "$0" >&2; exit 1 ;;
esac

version_output=$("$repo_dir/bin/agenticmode" --version)
case "$version_output" in
  'agenticmode '*) version=${version_output#agenticmode } ;;
  *) printf 'Could not read the CLI version\n' >&2; exit 1 ;;
esac
[ "$tag" = "v$version" ] || {
  printf 'Tag %s does not match CLI version %s\n' "$tag" "$version" >&2
  exit 1
}

mkdir -p "$output_dir"
output_dir=$(CDPATH= cd -- "$output_dir" && pwd)
temporary=$(mktemp -d "${TMPDIR:-/tmp}/agenticmode-release.XXXXXX") || exit 1
trap 'rm -rf "$temporary"' EXIT INT TERM HUP
package_root="$temporary/agenticmode"
mkdir -p "$package_root/bin" "$package_root/libexec"

/bin/cp "$repo_dir/install.sh" "$package_root/install.sh"
/bin/cp "$repo_dir/uninstall.sh" "$package_root/uninstall.sh"
/bin/cp "$repo_dir/config.example" "$package_root/config.example"
/bin/cp "$repo_dir/bin/agenticmode" "$package_root/bin/agenticmode"
/bin/cp "$repo_dir/libexec/agenticmode-watchdog" "$package_root/libexec/agenticmode-watchdog"
chmod 755 "$package_root/install.sh" "$package_root/uninstall.sh" \
  "$package_root/bin/agenticmode" "$package_root/libexec/agenticmode-watchdog"
chmod 644 "$package_root/config.example"

/usr/bin/tar -czf "$output_dir/agenticmode.tar.gz" -C "$temporary" agenticmode
(
  cd "$output_dir"
  /usr/bin/shasum -a 256 agenticmode.tar.gz > agenticmode.tar.gz.sha256
)
printf 'Packaged agenticmode %s in %s\n' "$version" "$output_dir"
