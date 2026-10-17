#!/bin/sh
# Install the rap command line tool and server without sudo:
#
#   curl -fsSL https://github.com/frinfo702/raptor/releases/latest/download/install-rap.sh | sh
#
# Downloads the rap release tarball for this OS and arch, verifies it
# against the release's rap-SHA256SUMS, and installs bin/rap and
# share/ghostty/shell-integration under ~/.local.
set -eu

repo=frinfo702/raptor

fail() {
  echo "install-rap: $*" >&2
  exit 1
}

fetch() {
  curl -fsSL -o "$2" "$1" || fail "could not download $1"
}

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    set -- "$(sha256sum "$1")"
  elif command -v shasum >/dev/null 2>&1; then
    set -- "$(shasum -a 256 "$1")"
  else
    fail "need sha256sum or shasum to verify the download"
  fi
  echo "${1%% *}"
}

# Everything runs from here, so a truncated download of this script
# installs nothing.
main() {
  case "$(uname -s)" in
    Darwin) os=macos ;;
    Linux) os=linux ;;
    *) fail "unsupported OS $(uname -s); rap runs on macOS and Linux" ;;
  esac
  case "$(uname -m)" in
    x86_64 | amd64) arch=x86_64 ;;
    arm64 | aarch64) arch=aarch64 ;;
    *) fail "unsupported CPU $(uname -m); rap runs on x86_64 and arm64" ;;
  esac
  # A shell under Rosetta reports x86_64 on Apple silicon.
  if [ "$os" = macos ] && [ "$(sysctl -n hw.optional.arm64 2>/dev/null)" = 1 ]; then
    arch=aarch64
  fi
  asset="rap-$os-$arch.tar.gz"

  base="https://github.com/$repo/releases/latest/download"
  prefix="$HOME/.local"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/install-rap.XXXXXX")"
  trap 'rm -rf "$tmp"' EXIT INT TERM

  echo "install-rap: downloading $base/$asset"
  fetch "$base/$asset" "$tmp/$asset"
  fetch "$base/rap-SHA256SUMS" "$tmp/rap-SHA256SUMS"
  want="$(awk -v f="$asset" '$2 == f {print $1}' "$tmp/rap-SHA256SUMS")"
  [ -n "$want" ] || fail "rap-SHA256SUMS has no entry for $asset"
  got="$(sha256 "$tmp/$asset")"
  [ "$got" = "$want" ] || fail "checksum mismatch for $asset: expected $want, got $got"

  mkdir "$tmp/x"
  tar -xzf "$tmp/$asset" -C "$tmp/x"
  [ -x "$tmp/x/bin/rap" ] || fail "$asset has no bin/rap"

  mkdir -p "$prefix/bin" "$prefix/share/ghostty"
  # Move into place so a running rap server keeps its old binary.
  cp "$tmp/x/bin/rap" "$prefix/bin/.rap.new"
  mv -f "$prefix/bin/.rap.new" "$prefix/bin/rap"
  rm -rf "$prefix/share/ghostty/shell-integration"
  cp -R "$tmp/x/share/ghostty/shell-integration" "$prefix/share/ghostty/"

  echo "install-rap: installed $prefix/bin/rap"
  case ":$PATH:" in
    *":$prefix/bin:"*) ;;
    *) echo "install-rap: add $prefix/bin to your PATH, e.g. in ~/.profile:
  export PATH=\"$prefix/bin:\$PATH\"" ;;
  esac
}

main "$@"
