#!/usr/bin/env bash
# Write a Sparkle appcast.xml for a Raptor DMG, signed with the EdDSA
# private key in $SPARKLE_PRIVATE_KEY.
#
#   dist/macos/raptor-appcast.sh <raptor-vX.Y.Z tag> <Raptor-X.Y.Z.dmg> [download URL prefix]
#
# Needs Sparkle's generate_appcast on PATH. The appcast lists only this
# release: the app reads it from releases/latest, so the newest is enough.
set -euo pipefail

tag="${1:?usage: raptor-appcast.sh <tag> <dmg> [download URL prefix]}"
dmg="${2:?usage: raptor-appcast.sh <tag> <dmg> [download URL prefix]}"
prefix="${3:-https://github.com/frinfo702/rex/releases/download/$tag/}"
: "${SPARKLE_PRIVATE_KEY:?SPARKLE_PRIVATE_KEY is not set}"

archives="$(mktemp -d)"
trap 'rm -rf "$archives"' EXIT
cp "$dmg" "$archives/"

printf '%s' "$SPARKLE_PRIVATE_KEY" |
  generate_appcast --ed-key-file - --download-url-prefix "$prefix" \
    --link "https://github.com/frinfo702/rex/releases/tag/$tag" \
    -o appcast.xml "$archives"
grep -q 'sparkle:edSignature=' appcast.xml ||
  { echo "error: appcast.xml has no EdDSA signature" >&2; exit 1; }
echo appcast.xml
