#!/bin/bash

set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_root=$(mktemp -d "${TMPDIR:-/tmp}/agenticmode-packaging-test.XXXXXX")
trap 'rm -rf "$test_root"' EXIT INT TERM HUP

fail() {
  printf 'Packaging test failed: %s\n' "$*" >&2
  exit 1
}

printf 'Test: universal UI build\n'
"$repo_dir/scripts/build-ui.sh" "$test_root/agenticmode-ui" > "$test_root/build.log"
[ -f "$test_root/agenticmode-ui" ] && [ -x "$test_root/agenticmode-ui" ] || fail "UI build is not executable"
architectures=$(/usr/bin/lipo -archs "$test_root/agenticmode-ui")
case " $architectures " in *' arm64 '*) ;; *) fail "UI build is missing arm64" ;; esac
case " $architectures " in *' x86_64 '*) ;; *) fail "UI build is missing x86_64" ;; esac
[ "$("$test_root/agenticmode-ui" --protocol-version)" = "1" ] || fail "UI protocol version is incompatible"

printf 'Test: source installer builds the UI when Go is available\n'
source_root="$test_root/source"
mkdir -p "$source_root/bin" "$source_root/libexec" "$source_root/scripts"
/bin/cp -R "$repo_dir/cmd" "$repo_dir/internal" "$source_root/"
/bin/cp "$repo_dir/go.mod" "$repo_dir/go.sum" "$repo_dir/install.sh" "$repo_dir/uninstall.sh" \
  "$repo_dir/config.example" "$source_root/"
/bin/cp "$repo_dir/bin/agenticmode" "$source_root/bin/agenticmode"
/bin/cp "$repo_dir/libexec/agenticmode-watchdog" "$source_root/libexec/agenticmode-watchdog"
/bin/cp "$repo_dir/scripts/build-ui.sh" "$source_root/scripts/build-ui.sh"
chmod 755 "$source_root/install.sh" "$source_root/uninstall.sh" "$source_root/bin/agenticmode" \
  "$source_root/libexec/agenticmode-watchdog" "$source_root/scripts/build-ui.sh"
PREFIX="$test_root/source-prefix" AGENTICMODE_TESTING=1 AGENTICMODE_TEST_BUILD_UI=1 \
  "$source_root/install.sh" > "$test_root/source-install.log"
[ -x "$source_root/libexec/agenticmode-ui" ] || fail "source installer did not build the UI companion"
source_architectures=$(/usr/bin/lipo -archs "$source_root/libexec/agenticmode-ui")
case " $source_architectures " in *' arm64 '*) ;; *) fail "source-installed UI is missing arm64" ;; esac
case " $source_architectures " in *' x86_64 '*) ;; *) fail "source-installed UI is missing x86_64" ;; esac

printf 'Test: UI builder refuses a symlinked destination\n'
ln -s "$test_root/unrelated" "$test_root/symlink-output"
if "$repo_dir/scripts/build-ui.sh" "$test_root/symlink-output" > "$test_root/symlink.log" 2>&1; then
  fail "UI builder replaced a symlinked destination"
fi

printf 'Test: release carries a backward-compatible core and universal UI companion\n'
version_output=$("$repo_dir/bin/agenticmode" --version)
case "$version_output" in
  'agenticmode '*) version=${version_output#agenticmode } ;;
  *) fail "CLI version output is malformed" ;;
esac
mkdir -p "$test_root/dist" "$test_root/extract"
"$repo_dir/scripts/package-release.sh" "v$version" "$test_root/dist" > "$test_root/package.log"
(
  cd "$test_root/dist"
  /usr/bin/shasum -a 256 -c agenticmode.tar.gz.sha256
) > "$test_root/checksum.log"
/usr/bin/tar -tzf "$test_root/dist/agenticmode.tar.gz" > "$test_root/archive.list"
[ "$(/usr/bin/grep -Fc 'agenticmode/libexec/agenticmode-ui' "$test_root/archive.list")" -eq 0 ] || \
  fail "core archive broke the v1.3 updater path allowlist"
[ -x "$test_root/dist/agenticmode-ui" ] || fail "release companion is missing"
(
  cd "$test_root/dist"
  /usr/bin/shasum -a 256 -c agenticmode-ui.sha256
) > "$test_root/ui-checksum.log"
/usr/bin/tar -xzf "$test_root/dist/agenticmode.tar.gz" -C "$test_root/extract"
packaged_ui="$test_root/dist/agenticmode-ui"
packaged_architectures=$(/usr/bin/lipo -archs "$packaged_ui")
case " $packaged_architectures " in *' arm64 '*) ;; *) fail "packaged UI is missing arm64" ;; esac
case " $packaged_architectures " in *' x86_64 '*) ;; *) fail "packaged UI is missing x86_64" ;; esac

printf 'Test: packaged installer verifies and downloads the release UI\n'
PREFIX="$test_root/prefix" AGENTICMODE_TESTING=1 \
  AGENTICMODE_UI_RELEASE_BASE_URL="file://$test_root/dist" \
  "$test_root/extract/agenticmode/install.sh" > "$test_root/install.log"
installed_ui="$test_root/extract/agenticmode/libexec/agenticmode-ui"
[ -x "$installed_ui" ] || fail "packaged installer omitted the UI companion"
packaged_root=$(CDPATH= cd -- "$test_root/extract/agenticmode" && pwd)
[ "$(readlink "$test_root/prefix/bin/agenticmode")" = "$packaged_root/bin/agenticmode" ] || \
  fail "packaged installer linked the wrong CLI"

printf 'Test: stable remote bootstrap verifies and installs the release UI\n'
stable_root="$test_root/stable-root"
stable_prefix="$test_root/stable-prefix"
empty_root="$test_root/empty"
mkdir -p "$empty_root"
(
  cd "$empty_root"
  PREFIX="$stable_prefix" \
    AGENTICMODE_TESTING=1 \
    AGENTICMODE_INSTALL_DIR="$stable_root" \
    AGENTICMODE_INSTALL_RELEASE_BASE_URL="file://$test_root/dist" \
    AGENTICMODE_UI_RELEASE_BASE_URL="file://$test_root/dist" \
    /bin/bash < "$repo_dir/install.sh"
) > "$test_root/stable-install.log"
[ -x "$stable_root/libexec/agenticmode-ui" ] || fail "stable bootstrap omitted the UI companion"
[ "$("$stable_root/libexec/agenticmode-ui" --protocol-version)" = "1" ] || \
  fail "stable bootstrap installed an incompatible UI companion"
stable_root_canonical=$(CDPATH= cd -- "$stable_root" && pwd)
[ "$(readlink "$stable_prefix/bin/am")" = "$stable_root_canonical/bin/agenticmode" ] || \
  fail "stable bootstrap linked the wrong CLI"

printf 'All packaging tests passed.\n'
