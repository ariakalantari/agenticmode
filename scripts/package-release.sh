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

if [ -f "$repo_dir/go.mod" ]; then
  [ -x "$repo_dir/scripts/build-ui.sh" ] || {
    printf 'The Go module is present but scripts/build-ui.sh is missing or not executable\n' >&2
    exit 1
  }
  "$repo_dir/scripts/build-ui.sh" "$output_dir/agenticmode-ui"
elif [ -f "$repo_dir/libexec/agenticmode-ui" ] && [ -x "$repo_dir/libexec/agenticmode-ui" ]; then
  /bin/cp "$repo_dir/libexec/agenticmode-ui" "$output_dir/agenticmode-ui"
else
  printf 'The release requires a built libexec/agenticmode-ui companion\n' >&2
  exit 1
fi
chmod 755 "$output_dir/agenticmode-ui"
ui_architectures=$(/usr/bin/lipo -archs "$output_dir/agenticmode-ui" 2>/dev/null || true)
case " $ui_architectures " in *' arm64 '*) ;; *) printf 'The release UI companion is missing arm64\n' >&2; exit 1 ;; esac
case " $ui_architectures " in *' x86_64 '*) ;; *) printf 'The release UI companion is missing x86_64\n' >&2; exit 1 ;; esac
[ "$("$output_dir/agenticmode-ui" --protocol-version 2>/dev/null)" = "1" ] || {
  printf 'The release UI companion has an incompatible protocol\n' >&2
  exit 1
}
[ "$("$output_dir/agenticmode-ui" --version 2>/dev/null)" = "agenticmode-ui $version" ] || {
  printf 'The release UI companion version does not match the CLI\n' >&2
  exit 1
}

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
  /usr/bin/shasum -a 256 agenticmode-ui > agenticmode-ui.sha256
)
printf 'Packaged agenticmode %s in %s\n' "$version" "$output_dir"
