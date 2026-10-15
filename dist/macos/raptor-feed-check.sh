#!/usr/bin/env bash
# Fail when installed apps could not fetch the update feed.
#
#   dist/macos/raptor-feed-check.sh <Raptor.app>
#
# Sparkle sends no GitHub credentials, so a private repository (or a
# deleted release asset) leaves installed apps with "Update Error!" even
# though every release upload succeeds. Fetches the app's own SUFeedURL
# and every enclosure the returned appcast lists with no credentials, and
# fails on any non-200. Apps predating the Raptor updater have no
# SUFeedURL and are skipped, like the appcast upload does.
set -euo pipefail

app="${1:?usage: raptor-feed-check.sh <path to Raptor.app>}"
plist="$app/Contents/Info.plist"
[ -f "$plist" ] || { echo "error: $plist not found" >&2; exit 1; }
feed="$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$plist" 2>/dev/null)" || {
  echo "notice: $app has no SUFeedURL; skipping the feed check" >&2
  exit 0
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "Fetching $feed without credentials"
curl -fsSL --retry 3 "$feed" -o "$tmp/appcast.xml"

urls="$(grep -o '<enclosure url="[^"]*"' "$tmp/appcast.xml" |
  sed 's/^<enclosure url="//; s/"$//' || true)"
[ -n "$urls" ] || { echo "error: $feed lists no enclosure" >&2; exit 1; }

while IFS= read -r url; do
  echo "Fetching $url without credentials"
  curl -fsSL --retry 3 "$url" -o /dev/null
done <<<"$urls"

echo "The feed and its enclosures are fetchable without credentials"
