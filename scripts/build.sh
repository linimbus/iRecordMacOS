#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
IDENTITY="${CODESIGN_IDENTITY:--}"
UNIVERSAL="${UNIVERSAL:-1}"
BUILD_CONFIG="${BUILD_CONFIG:-release}"

echo "==> iRecord $VERSION ($BUILD_CONFIG, universal=$UNIVERSAL)"

if [[ ! -f Resources/AppIcon.icns ]]; then
    echo "==> Generating app icon"
    rm -rf Resources/AppIcon.iconset
    swift scripts/make_icon.swift Resources/AppIcon.iconset
    iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns
fi

echo "==> Building binaries"
if [[ "$UNIVERSAL" == "1" ]]; then
    swift build -c "$BUILD_CONFIG" --arch arm64 --arch x86_64 --product iRecordApp
    swift build -c "$BUILD_CONFIG" --arch arm64 --arch x86_64 --product irecord
    BUILD_DIR="$(swift build -c "$BUILD_CONFIG" --arch arm64 --arch x86_64 --show-bin-path)"
else
    swift build -c "$BUILD_CONFIG" --product iRecordApp
    swift build -c "$BUILD_CONFIG" --product irecord
    BUILD_DIR="$(swift build -c "$BUILD_CONFIG" --show-bin-path)"
fi

for binary in iRecordApp irecord; do
    if [[ ! -f "$BUILD_DIR/$binary" ]]; then
        echo "error: missing $BUILD_DIR/$binary" >&2
        exit 1
    fi
done

echo "==> Assembling iRecord.app"
rm -rf dist
mkdir -p dist/iRecord.app/Contents/MacOS
mkdir -p dist/iRecord.app/Contents/Helpers
mkdir -p dist/iRecord.app/Contents/Resources

# macOS volumes are case-insensitive: the app executable "iRecord" and the
# CLI "irecord" must not live in the same directory. Helpers is the standard
# location for a bundled command-line helper.
cp "$BUILD_DIR/iRecordApp" dist/iRecord.app/Contents/MacOS/iRecord
cp "$BUILD_DIR/irecord" dist/iRecord.app/Contents/Helpers/irecord
cp Resources/Info.plist dist/iRecord.app/Contents/Info.plist
cp Resources/AppIcon.icns dist/iRecord.app/Contents/Resources/AppIcon.icns
chmod +x dist/iRecord.app/Contents/MacOS/iRecord dist/iRecord.app/Contents/Helpers/irecord
printf 'APPL????' > dist/iRecord.app/Contents/PkgInfo

echo "==> Signing"
if [[ "$IDENTITY" == "-" ]]; then
    codesign --force --sign - --entitlements Resources/iRecord.entitlements dist/iRecord.app/Contents/Helpers/irecord
    codesign --force --sign - --entitlements Resources/iRecord.entitlements dist/iRecord.app
else
    codesign --force --options runtime --timestamp --sign "$IDENTITY" --entitlements Resources/iRecord.entitlements dist/iRecord.app/Contents/Helpers/irecord
    codesign --force --options runtime --timestamp --sign "$IDENTITY" --entitlements Resources/iRecord.entitlements dist/iRecord.app
fi
codesign --verify --deep --strict --verbose=2 dist/iRecord.app

echo "==> Standalone CLI"
cp "$BUILD_DIR/irecord" dist/irecord
codesign --force --sign "$IDENTITY" dist/irecord

echo "==> Archives"
ditto -c -k --keepParent dist/iRecord.app "dist/iRecord-$VERSION-macOS.zip"

rm -rf dist/dmg-staging
mkdir -p dist/dmg-staging
cp -R dist/iRecord.app dist/dmg-staging/
ln -s /Applications dist/dmg-staging/Applications
mkdir -p dist/dmg-staging/Documentation
cp README.md README_en.md LICENSE dist/dmg-staging/Documentation/ 2>/dev/null || true
cp -R skill dist/dmg-staging/Documentation/ 2>/dev/null || true
cp -R docs dist/dmg-staging/Documentation/ 2>/dev/null || true
mkdir -p dist/dmg-staging/CLI
cp dist/irecord dist/dmg-staging/CLI/
hdiutil create \
    -volname "iRecord $VERSION" \
    -srcfolder dist/dmg-staging \
    -ov -format UDZO \
    "dist/iRecord-$VERSION-macOS.dmg" >/dev/null
rm -rf dist/dmg-staging

(
    cd dist
    shasum -a 256 "iRecord-$VERSION-macOS.zip" "iRecord-$VERSION-macOS.dmg" irecord > SHA256SUMS.txt
)

echo ""
echo "==> Done"
ls -lh dist
echo ""
echo "App:  dist/iRecord.app"
echo "Zip:  dist/iRecord-$VERSION-macOS.zip"
echo "DMG:  dist/iRecord-$VERSION-macOS.dmg"
echo "CLI:  dist/irecord"
echo ""
echo "Release notes: this build is ad-hoc signed unless CODESIGN_IDENTITY was set."
echo "On another Mac, right-click the app and choose Open, or clear the quarantine flag:"
echo "  xattr -dr com.apple.quarantine /Applications/iRecord.app"
