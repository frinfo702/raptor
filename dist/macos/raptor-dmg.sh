#!/usr/bin/env bash
# Build Raptor.app, ad-hoc sign it, and package it as a DMG.
#
#   dist/macos/raptor-dmg.sh <raptor-vX.Y.Z tag> [zig command...]
#
# Builds the source tree in $RAPTOR_SRC (default: this script's repository),
# so CI can build an old tag with current tooling. Writes Raptor-X.Y.Z.dmg
# to that tree's root and prints its path.
# The zig command defaults to `zig`; locally use `direnv exec . zig`.
set -euo pipefail

tag="${1:?usage: raptor-dmg.sh <raptor-vX.Y.Z tag> [zig command...]}"
shift
[[ "$tag" =~ ^raptor-v([0-9]+\.[0-9]+\.[0-9]+)$ ]] ||
  { echo "error: tag '$tag' is not in raptor-vX.Y.Z format" >&2; exit 1; }
version="${BASH_REMATCH[1]}"
zig=("$@")
[ ${#zig[@]} -gt 0 ] || zig=(zig)

cd "${RAPTOR_SRC:-$(dirname "$0")/../..}"
# Native (arm64 on Apple silicon) because the bundled rap is built for
# the host only; a universal app would ship an arm64-only rap.
# An explicit version skips git tag detection, which rejects raptor-v* tags.
"${zig[@]}" build -Doptimize=ReleaseFast -Dxcframework-target=native \
  -Dversion-string="$version"

app=zig-out/Raptor.app
[ -x "$app/Contents/MacOS/rap" ] || { echo "error: $app has no bundled rap" >&2; exit 1; }

# Sparkle compares CFBundleVersion against the appcast's sparkle:version,
# so both carry the tag's version. Dropping SUEnableAutomaticChecks lets
# the auto-update config decide, as in Ghostty's release builds.
/usr/libexec/PlistBuddy \
  -c "Set :CFBundleVersion $version" \
  -c "Set :CFBundleShortVersionString $version" \
  -c "Delete :SUEnableAutomaticChecks" \
  "$app/Contents/Info.plist"

# Ad-hoc signature: no Apple Developer account needed, but Gatekeeper
# will still ask the user to approve the app on first launch.
codesign --force --deep --sign - "$app"
# An ad-hoc signature's default designated requirement is its cdhash, so
# macOS privacy grants (Accessibility for global keybinds) would not
# survive an update. Pin it to the bundle id instead, as Xcode does.
codesign --force --sign - \
  --requirements '=designated => identifier "com.frinfo702.raptor"' "$app"
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
