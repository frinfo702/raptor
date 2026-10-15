#!/usr/bin/env bash
# Sign Raptor.app so macOS privacy grants (Accessibility, needed by
# global keybinds) survive rebuilds and updates.
#
#   dist/macos/raptor-sign.sh <app> <bundle id> [identity SHA-1]
#
# macOS stores a grant with the app's designated requirement. With a
# certificate identity the requirement is the bundle id plus that
# certificate, so only builds signed with it share the grant. Without
# one (or if signing with it fails) the app is ad-hoc signed, whose
# default requirement is its cdhash and changes on every build, so the
# requirement is pinned to the bundle id alone. Any app can claim that
# id, so the fallback is weaker and prints a warning. With
# RAPTOR_REQUIRE_IDENTITY=1 (release CI with the certificate imported)
# the script fails instead of falling back.
set -euo pipefail

app="${1:?usage: raptor-sign.sh <app> <bundle id> [identity SHA-1]}"
bundle_id="${2:?usage: raptor-sign.sh <app> <bundle id> [identity SHA-1]}"
identity="${3:-}"

# Show codesign's output only on failure, hiding "replacing existing
# signature" notices.
cs() {
  local out
  out="$(codesign "$@" 2>&1)" || { echo "$out" >&2; return 1; }
}

# sign <identity> <designated requirement>
sign() {
  local nested
  # Nested code first, each keeping its own default requirement, so the
  # outer signature seals the re-signed versions.
  for nested in "$app"/Contents/MacOS/rap "$app"/Contents/Frameworks/* "$app"/Contents/PlugIns/*; do
    [ -e "$nested" ] || continue
    cs --force --deep --sign "$1" --preserve-metadata=entitlements,flags "$nested" || return
  done
  cs --force --sign "$1" --preserve-metadata=entitlements,flags \
    --requirements "=designated => $2" "$app" || return
}

if [ -z "$identity" ]; then
  reason="no signing identity given"
elif ! security find-identity -p codesigning | grep -qw -- "$identity"; then
  reason="identity $identity is not in the keychain"
elif sign "$identity" "identifier \"$bundle_id\" and certificate leaf = H\"$(tr 'A-F' 'a-f' <<<"$identity")\""; then
  exit 0
else
  reason="codesign with identity $identity failed"
fi

if [ "${RAPTOR_REQUIRE_IDENTITY:-}" = 1 ]; then
  echo "::error::$reason; refusing to ad-hoc sign $app because RAPTOR_REQUIRE_IDENTITY=1" >&2
  exit 1
fi
echo "warning: $reason; ad-hoc signing $app. Accessibility grants then match any app claiming $bundle_id." >&2
sign - "identifier \"$bundle_id\""
