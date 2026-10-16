#!/usr/bin/env bash
# Build the standalone rap tarballs that dist/rap/install.sh downloads.
#
#   dist/rap/rap-release.sh <raptor-vX.Y.Z tag> [zig command...]
#
# Builds the source tree in $RAPTOR_SRC (default: this script's repository)
# for macOS and Linux on aarch64 and x86_64, and writes
# rap-<os>-<arch>.tar.gz plus rap-SHA256SUMS to that tree's root. Each tarball holds bin/rap and the
# share/ghostty/shell-integration it looks for beside itself.
# Linux builds are static musl, so they run on any distribution.
# The zig command defaults to `zig`; locally use `direnv exec . zig`.
set -euo pipefail

tag="${1:?usage: rap-release.sh <raptor-vX.Y.Z tag> [zig command...]}"
shift
[[ "$tag" =~ ^raptor-v([0-9]+\.[0-9]+\.[0-9]+)$ ]] ||
  { echo "error: tag '$tag' is not in raptor-vX.Y.Z format" >&2; exit 1; }
version="${BASH_REMATCH[1]}"
zig=("$@")
[ ${#zig[@]} -gt 0 ] || zig=(zig)

cd "${RAPTOR_SRC:-$(dirname "$0")/../..}"
out="$PWD"
staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT

# rap-<os>-<arch> names the asset install.sh picks from `uname -sm`.
assets=()
for target in aarch64-macos x86_64-macos x86_64-linux-musl aarch64-linux-musl; do
  IFS=- read -r arch os _ <<<"$target"
  name="$os-$arch"
  prefix="$staging/rap-$name"
  # Same runtime and font flags as Rex CI: rap needs neither GTK nor
  # fontconfig. An explicit version skips git tag detection, which
  # rejects raptor-v* tags.
  "${zig[@]}" build rap -Doptimize=ReleaseFast -Dtarget="$target" \
    -Dapp-runtime=none -Dfont-backend=freetype \
    -Dversion-string="$version" --prefix "$prefix"
  # Without macOS xattrs, which GNU tar warns about on extraction.
  tar --no-xattrs --no-mac-metadata -czf "$out/rap-$name.tar.gz" -C "$prefix" bin share
  assets+=("rap-$name.tar.gz")
done

(cd "$out" && shasum -a 256 "${assets[@]}" > rap-SHA256SUMS)
cat "$out/rap-SHA256SUMS"
