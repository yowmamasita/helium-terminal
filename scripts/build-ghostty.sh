#!/bin/sh
# Builds GhosttyKit.xcframework (libghostty) from vendor/ghostty. Needs Zig 0.16.0.
set -eu
cd "$(dirname "$0")/.."
REV=$(sed -n 's/^ghostty commit: //p' vendor.lock)
[ -d vendor/ghostty ] || git clone https://github.com/ghostty-org/ghostty.git vendor/ghostty
git -C vendor/ghostty fetch --depth 1 origin "$REV" && git -C vendor/ghostty checkout -q "$REV"
cd vendor/ghostty
git checkout -q -- . && git apply ../../patches/*.patch
ZIG="${ZIG:-$(mise which zig 2>/dev/null || command -v zig)}"
rm -rf macos/GhosttyKit.xcframework
# ReleaseFast: ReleaseSmall saves 3 MB but parses escape-heavy output ~40% slower.
# No Sentry crash reporter, no translations.
"$ZIG" build -Doptimize=ReleaseFast -Dsentry=false -Di18n=false -Demit-xcframework=true -Demit-macos-app=false -Dxcframework-target=native
# SwiftPM does not notice a rebuilt xcframework; force a relink.
rm -rf ../../.build
