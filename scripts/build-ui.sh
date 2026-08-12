#!/bin/bash

set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
output_path="${1:-$repo_dir/libexec/agenticmode-ui}"
target_os="${AGENTICMODE_UI_GOOS:-darwin}"
target_arch="${AGENTICMODE_UI_GOARCH:-}"
package="${AGENTICMODE_UI_PACKAGE:-./cmd/agenticmode-ui}"
go_bin="${GO:-}"

if [ -z "$go_bin" ]; then
  go_bin=$(command -v go 2>/dev/null || true)
elif [ "${go_bin#/}" = "$go_bin" ]; then
  go_bin=$(command -v "$go_bin" 2>/dev/null || true)
fi
[ -n "$go_bin" ] && [ -x "$go_bin" ] || {
  printf 'build-ui.sh: Go is required to build agenticmode-ui\n' >&2
  exit 1
}
[ -f "$repo_dir/go.mod" ] || {
  printf 'build-ui.sh: %s was not found\n' "$repo_dir/go.mod" >&2
  exit 1
}

case "$target_os" in darwin) ;; *) printf 'build-ui.sh: unsupported target OS: %s\n' "$target_os" >&2; exit 1 ;; esac
if [ -n "$target_arch" ]; then
  case "$target_arch" in arm64|amd64) ;; *) printf 'build-ui.sh: unsupported target architecture: %s\n' "$target_arch" >&2; exit 1 ;; esac
fi

output_dir=${output_path%/*}
[ "$output_dir" != "$output_path" ] || output_dir=.
mkdir -p "$output_dir"
output_dir=$(CDPATH= cd -- "$output_dir" && pwd)
output_path="$output_dir/${output_path##*/}"
[ ! -L "$output_path" ] || {
  printf 'build-ui.sh: refusing symlinked output path: %s\n' "$output_path" >&2
  exit 1
}
temporary=$(mktemp -d "${TMPDIR:-/tmp}/agenticmode-ui-build.XXXXXX") || exit 1
trap 'rm -rf "$temporary"' EXIT INT TERM HUP

build_arch() {
  local arch="$1" destination="$2"
  (
    cd "$repo_dir"
    CGO_ENABLED=0 GOOS="$target_os" GOARCH="$arch" GOWORK=off GOFLAGS='-mod=readonly' \
      "$go_bin" build -trimpath -buildvcs=false -ldflags='-s -w' -o "$destination" "$package"
  )
  chmod 755 "$destination"
}

if [ -n "$target_arch" ]; then
  build_arch "$target_arch" "$temporary/agenticmode-ui"
else
  command -v /usr/bin/lipo >/dev/null 2>&1 || {
    printf 'build-ui.sh: /usr/bin/lipo is required for a universal macOS build\n' >&2
    exit 1
  }
  build_arch arm64 "$temporary/agenticmode-ui-arm64"
  build_arch amd64 "$temporary/agenticmode-ui-amd64"
  /usr/bin/lipo -create \
    "$temporary/agenticmode-ui-arm64" "$temporary/agenticmode-ui-amd64" \
    -output "$temporary/agenticmode-ui"
  chmod 755 "$temporary/agenticmode-ui"
  architecture_info=$(/usr/bin/lipo -archs "$temporary/agenticmode-ui" 2>/dev/null || true)
  case " $architecture_info " in *' arm64 '*) ;; *) printf 'build-ui.sh: universal binary is missing arm64\n' >&2; exit 1 ;; esac
  case " $architecture_info " in *' x86_64 '*) ;; *) printf 'build-ui.sh: universal binary is missing x86_64\n' >&2; exit 1 ;; esac
fi

/usr/bin/install -m 755 "$temporary/agenticmode-ui" "$output_path"
printf 'Built %s\n' "$output_path"
