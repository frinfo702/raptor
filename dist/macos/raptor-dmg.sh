#!/usr/bin/env bash
# Build Raptor.app, ad-hoc sign it, and package it as a DMG.
#
#   dist/macos/raptor-dmg.sh <version> [zig command...]
#
# Writes Raptor-<version>.dmg to the repository root and prints its path.
# The zig command defaults to `zig`; locally use `direnv exec . zig`.
set -euo pipefail

version="${1:?usage: raptor-dmg.sh <version> [zig command...]}"
shift
zig=("$@")
[ ${#zig[@]} -gt 0 ] || zig=(zig)

cd "$(dirname "$0")/../.."
# Native (arm64 on Apple silicon) because the bundled rap is built for
# the host only; a universal app would ship an arm64-only rap.
"${zig[@]}" build -Doptimize=ReleaseFast -Dxcframework-target=native

app=zig-out/Raptor.app
[ -x "$app/Contents/MacOS/rap" ] || { echo "error: $app has no bundled rap" >&2; exit 1; }

# Ad-hoc signature: no Apple Developer account needed, but Gatekeeper
# will still ask the user to approve the app on first launch.
codesign --force --deep --sign - "$app"
codesign --verify --deep --strict "$app"

staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT
cp -R "$app" "$staging/"
ln -s /Applications "$staging/Applications"

dmg="Raptor-$version.dmg"
rm -f "$dmg"
hdiutil create -volname "Raptor $version" -srcfolder "$staging" \
  -fs HFS+ -format UDZO -ov "$dmg" >&2
echo "$dmg"
