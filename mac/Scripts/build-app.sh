#!/bin/bash
# Builds "QingYi Translator.app" (universal with Xcode, current architecture with the Command Line Tools) and zips it.
# Needs only the Xcode Command Line Tools (Swift 6). Output: mac/build/
#   CONFIG=debug ./Scripts/build-app.sh      # faster, current architecture only
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
# A universal (arm64 + x86_64) build needs Xcode's build system; with only the Command Line Tools,
# SwiftPM can build for the current architecture alone. GitHub Actions (see .github/workflows/mac.yml) has Xcode.
ARCH_FLAGS=""
if [[ "$CONFIG" == "release" ]]; then
    if [[ "$(xcode-select -p 2>/dev/null)" == *"Xcode.app"* ]]; then
        ARCH_FLAGS="--arch arm64 --arch x86_64"
    else
        echo "note: Xcode not selected; building for $(uname -m) only (CI builds the universal binary)"
    fi
fi

# shellcheck disable=SC2086
swift build -c "$CONFIG" $ARCH_FLAGS
# shellcheck disable=SC2086
BIN_DIR="$(swift build -c "$CONFIG" $ARCH_FLAGS --show-bin-path)"

APP="build/QingYi Translator.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/QingYiTranslator" "$APP/Contents/MacOS/QingYiTranslator"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp -R Resources/zh-Hans.lproj Resources/en.lproj "$APP/Contents/Resources/"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Ad-hoc signature: Apple silicon refuses to run unsigned binaries. Gatekeeper still asks for a right-click → Open
# the first time, because there is no Developer ID certificate.
codesign --force --deep --sign - "$APP"

rm -f build/QingYiTranslator-mac.zip
ditto -c -k --keepParent "$APP" build/QingYiTranslator-mac.zip
echo "Built $APP"
echo "Archive: build/QingYiTranslator-mac.zip ($(du -h build/QingYiTranslator-mac.zip | cut -f1))"
