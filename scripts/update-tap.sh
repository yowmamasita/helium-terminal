#!/bin/bash
# Writes the cask and the zerobrew formula for a released version into the tap.
#
#   scripts/update-tap.sh v0.1.0
#
# Checksums come from the release's own SHA256SUMS, so the tap can only ever
# agree with what was published.
set -euo pipefail
cd "$(dirname "$0")/.."

REPO="yowmamasita/helium-terminal"
TAP="yowmamasita/homebrew-tap"
TAG=${1:-$(gh release view --repo "$REPO" --json tagName -q .tagName)}
VERSION=${TAG#v}

sums=$(gh release download "$TAG" --repo "$REPO" --pattern SHA256SUMS --output -)
zip_sha=$(awk -v a="helium-terminal-$VERSION-macos-arm64.zip" '$2 == a {print $1}' <<< "$sums")
bottle_sha=$(awk -v a="helium-terminal-$VERSION.arm64_ventura.bottle.tar.gz" '$2 == a {print $1}' <<< "$sums")
src_sha=$(curl -fsSL "https://github.com/$REPO/archive/refs/tags/$TAG.tar.gz" | shasum -a 256 | cut -d' ' -f1)
[[ -n "$zip_sha" && -n "$bottle_sha" && -n "$src_sha" ]] || { echo "missing checksums for $TAG" >&2; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
gh repo clone "$TAP" "$tmp/tap" -- --quiet
fill() { sed -e "s/__VERSION__/$VERSION/g" -e "s/__ZIP_SHA__/$zip_sha/" -e "s/__BOTTLE_SHA__/$bottle_sha/" -e "s/__SRC_SHA__/$src_sha/" "$1"; }
fill packaging/helium-terminal.cask.rb > "$tmp/tap/Casks/helium-terminal.rb"
fill packaging/helium-terminal.formula.rb > "$tmp/tap/Formula/helium-terminal.rb"

cd "$tmp/tap"
git add Casks/helium-terminal.rb Formula/helium-terminal.rb
if git diff --cached --quiet; then echo "==> tap already at $VERSION"; exit 0; fi
git -c user.name="$(git -C "$OLDPWD" config user.name)" -c user.email="$(git -C "$OLDPWD" config user.email)" \
  commit -qm "helium-terminal $VERSION"
git push -q origin HEAD
echo "==> tap updated to $VERSION"
