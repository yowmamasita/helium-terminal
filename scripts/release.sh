#!/bin/bash
# Builds, signs, notarizes and publishes the release for the version in VERSION,
# then updates the Homebrew tap.
#
#   NOTARY_PROFILE=helium scripts/release.sh
#
# NOTARY_PROFILE names notarytool credentials saved once with
#   xcrun notarytool store-credentials helium --key AuthKey_XXXX.p8 --key-id XXXX --issuer <uuid>
# (or --apple-id/--team-id/--password). SIGN_IDENTITY defaults to the first
# "Developer ID Application" certificate in the keychain.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(cat VERSION)
TAG="v$VERSION"
: "${NOTARY_PROFILE:?set NOTARY_PROFILE (see the header of this script)}"
SIGN_IDENTITY=${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)}
[[ -n "$SIGN_IDENTITY" ]] || { echo "no Developer ID Application certificate found" >&2; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo "commit your changes first" >&2; exit 1; }
gh release view "$TAG" >/dev/null 2>&1 && { echo "$TAG is already released" >&2; exit 1; }

APP="build/Helium Terminal.app"
DIST=dist
rm -rf "$DIST" && mkdir -p "$DIST"

echo "==> build and sign ($SIGN_IDENTITY)"
SIGN_IDENTITY="$SIGN_IDENTITY" scripts/build-app.sh

echo "==> notarize"
ditto -c -k --keepParent "$APP" "$DIST/notarize.zip"
xcrun notarytool submit "$DIST/notarize.zip" --keychain-profile "$NOTARY_PROFILE" --wait
rm "$DIST/notarize.zip"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=2 "$APP"

echo "==> package"
ZIP="helium-terminal-$VERSION-macos-arm64.zip"
ditto -c -k --keepParent "$APP" "$DIST/$ZIP"
# A Homebrew-style bottle for zerobrew: <name>/<version>/ is the keg.
BOTTLE="helium-terminal-$VERSION.arm64_ventura.bottle.tar.gz"
KEG="$DIST/keg/helium-terminal/$VERSION"
mkdir -p "$KEG/bin"
ditto "$APP" "$KEG/Helium Terminal.app"
ln -s "../Helium Terminal.app/Contents/MacOS/helium-terminal" "$KEG/bin/helium"
cp LICENSE README.md "$KEG/"
tar -czf "$DIST/$BOTTLE" -C "$DIST/keg" helium-terminal
rm -rf "$DIST/keg"
(cd "$DIST" && shasum -a 256 "$ZIP" "$BOTTLE" > SHA256SUMS)
cat "$DIST/SHA256SUMS"

echo "==> publish $TAG"
git tag -a "$TAG" -m "Helium Terminal $VERSION" 2>/dev/null || true
git push origin HEAD "$TAG"
gh release create "$TAG" "$DIST/$ZIP" "$DIST/$BOTTLE" "$DIST/SHA256SUMS" \
  --title "Helium Terminal $VERSION" --notes-file "packaging/notes/$VERSION.md"

scripts/update-tap.sh "$TAG"
