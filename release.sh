#!/bin/bash
# One-click release builder for iRecord.
#
# Usage:
#   ./release.sh                 # test, build, package and verify
#   ./release.sh --open          # same, then open the dist folder
#   ./release.sh --no-tests      # skip unit tests
#   CODESIGN_IDENTITY="Developer ID Application: ..." ./release.sh
#
# Environment:
#   UNIVERSAL=0                  # build only the current architecture
#   CODESIGN_IDENTITY=<identity> # Developer ID identity; default is ad-hoc "-"
#   BUILD_CONFIG=release         # Swift build configuration

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

DIST="$ROOT/dist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
SOURCE_VERSION="$(sed -n 's/.*public static let version = "\([^"]*\)".*/\1/p' Sources/iRecordCore/Paths.swift | head -1)"
IDENTITY="${CODESIGN_IDENTITY:--}"
UNIVERSAL="${UNIVERSAL:-1}"
BUILD_CONFIG="${BUILD_CONFIG:-release}"
RUN_TESTS=1
OPEN_AFTER=0

usage() {
    cat <<EOF
iRecord one-click release

Usage:
  ./release.sh [options]

Options:
  --open          Open the dist folder after the release is ready
  --no-tests      Skip unit tests
  -h, --help      Show this help

Environment:
  CODESIGN_IDENTITY   Signing identity (default: ad-hoc "-")
  UNIVERSAL=0         Build only the current architecture
  BUILD_CONFIG        Swift build configuration (default: release)

The script runs tests, builds a universal .app, signs it, creates
.zip/.dmg artifacts, checksums them, and verifies the result.
EOF
}

for argument in "$@"; do
    case "$argument" in
        --open)
            OPEN_AFTER=1
            ;;
        --no-tests|--skip-tests)
            RUN_TESTS=0
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "error: unknown option: $argument" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "error: iRecord can only be built on macOS." >&2
    exit 1
fi

for tool in swift xcrun plutil codesign lipo hdiutil shasum ditto iconutil; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "error: required tool not found: $tool" >&2
        exit 1
    fi
done

if [[ -z "$VERSION" ]]; then
    echo "error: could not read the version from Resources/Info.plist." >&2
    exit 1
fi
if [[ -n "$SOURCE_VERSION" && "$VERSION" != "$SOURCE_VERSION" ]]; then
    echo "error: version mismatch: Info.plist=$VERSION, AppInfo.version=$SOURCE_VERSION" >&2
    echo "       Update Resources/Info.plist and Sources/iRecordCore/Paths.swift together." >&2
    exit 1
fi

echo "============================================================"
echo " iRecord $VERSION — one-click release"
echo "============================================================"
echo "identity:   $IDENTITY"
echo "universal:  $UNIVERSAL"
echo "config:     $BUILD_CONFIG"
echo ""

if [[ "$RUN_TESTS" == "1" ]]; then
    echo "==> Running unit tests"
    swift test
    echo ""
fi

echo "==> Building, signing and packaging"
UNIVERSAL="$UNIVERSAL" BUILD_CONFIG="$BUILD_CONFIG" CODESIGN_IDENTITY="$IDENTITY" "$ROOT/scripts/build.sh"

APP="$DIST/iRecord.app"
HELPER="$APP/Contents/Helpers/irecord"
CLI="$DIST/irecord"
INFO="$APP/Contents/Info.plist"
DMG="$DIST/iRecord-$VERSION-macOS.dmg"
ZIP="$DIST/iRecord-$VERSION-macOS.zip"
SUMS="$DIST/SHA256SUMS.txt"
MOUNT=""

cleanup_mount() {
    if [[ -n "$MOUNT" ]]; then
        hdiutil detach "$MOUNT" >/dev/null 2>&1 || true
        MOUNT=""
    fi
}
trap cleanup_mount EXIT

echo ""
echo "==> Verifying release"

for required in "$APP" "$HELPER" "$CLI" "$DMG" "$ZIP" "$SUMS" "$INFO"; do
    if [[ ! -e "$required" ]]; then
        echo "error: missing release artifact: $required" >&2
        exit 1
    fi
done

plutil -lint "$INFO" >/dev/null
if ! /usr/libexec/PlistBuddy -c 'Print :NSMicrophoneUsageDescription' "$INFO" >/dev/null 2>&1; then
    echo "error: NSMicrophoneUsageDescription is missing from the app Info.plist." >&2
    exit 1
fi

codesign --verify --deep --strict "$APP"

APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO")"
if [[ "$APP_VERSION" != "$VERSION" ]]; then
    echo "error: packaged app version $APP_VERSION does not match $VERSION." >&2
    exit 1
fi

if ! "$HELPER" version | grep -q "$VERSION"; then
    echo "error: bundled CLI version check failed." >&2
    exit 1
fi
if ! "$CLI" version | grep -q "$VERSION"; then
    echo "error: standalone CLI version check failed." >&2
    exit 1
fi

if [[ "$UNIVERSAL" == "1" ]]; then
    APP_ARCHS="$(lipo -archs "$APP/Contents/MacOS/iRecord")"
    HELPER_ARCHS="$(lipo -archs "$HELPER")"
    CLI_ARCHS="$(lipo -archs "$CLI")"
    for archs in "$APP_ARCHS" "$HELPER_ARCHS" "$CLI_ARCHS"; do
        if [[ "$archs" != *"arm64"* || "$archs" != *"x86_64"* ]]; then
            echo "error: expected a universal binary, got: $archs" >&2
            exit 1
        fi
    done
fi

(
    cd "$DIST"
    shasum -a 256 -c "$(basename "$SUMS")" >/dev/null
)

hdiutil verify "$DMG" >/dev/null

MOUNT="$(hdiutil attach -nobrowse -readonly "$DMG" | sed -n 's|^.*\(/Volumes/.*\)$|\1|p' | tail -1)"
if [[ -z "$MOUNT" ]]; then
    echo "error: could not mount the release DMG for verification." >&2
    exit 1
fi
if [[ ! -d "$MOUNT/iRecord.app" ]]; then
    echo "error: iRecord.app is missing from the DMG." >&2
    exit 1
fi
if [[ ! -f "$MOUNT/Documentation/skill/irecord-headless/SKILL.md" ]]; then
    echo "error: the LLM skill is missing from the DMG documentation." >&2
    exit 1
fi
if [[ ! -x "$MOUNT/CLI/irecord" ]]; then
    echo "error: the standalone CLI is missing from the DMG." >&2
    exit 1
fi
cleanup_mount

echo ""
echo "============================================================"
echo " Release ready: iRecord $VERSION"
echo "============================================================"
printf " App:  %s\n" "$APP"
printf " ZIP:  %s\n" "$ZIP"
printf " DMG:  %s\n" "$DMG"
printf " CLI:  %s\n" "$CLI"
printf " SHA:  %s\n" "$SUMS"
echo ""
cat "$SUMS"
echo ""
echo "Note: the default ad-hoc signature is not notarized. For public"
echo "distribution set CODESIGN_IDENTITY to a Developer ID identity and"
echo "notarize the DMG with notarytool."
echo ""

if [[ "$OPEN_AFTER" == "1" ]]; then
    open "$DIST"
fi
