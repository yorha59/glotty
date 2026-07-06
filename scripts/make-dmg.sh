#!/usr/bin/env bash
# Build Glotty in Release configuration and package it as a .dmg
# containing the app plus an Applications symlink so the user can
# drag-and-drop install.
#
# Output: dist/Glotty-<version>.dmg in the repo root.
#
# Signing: relies on the project's existing `Apple Development`
# identity. Good enough for personal install; for distribution to
# other machines you'd want Developer ID + notarization (separate
# step, not covered here).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

SCHEME="Glotty"
CONFIG="Release"
APP_NAME="Glotty.app"
DIST_DIR="$REPO_ROOT/dist"
BUILD_DIR="$(mktemp -d -t glotty-dmg)"
trap 'rm -rf "$BUILD_DIR"' EXIT

# Version string for the dmg filename. Use the short CFBundleVersion
# from the built Info.plist; falls back to a timestamp if missing.
VERSION_FALLBACK="$(date +%Y%m%d-%H%M)"

echo "==> Building $SCHEME ($CONFIG)"
xcodebuild \
    -scheme "$SCHEME" \
    -configuration "$CONFIG" \
    -destination "platform=macOS" \
    -derivedDataPath "$BUILD_DIR/derived" \
    CODE_SIGNING_REQUIRED=YES \
    build \
    | tail -20

APP_SRC="$BUILD_DIR/derived/Build/Products/$CONFIG/$APP_NAME"
if [ ! -d "$APP_SRC" ]; then
    echo "ERROR: built app not found at $APP_SRC"
    exit 1
fi

# Resolve a version. The Info.plist key is CFBundleShortVersionString
# (the user-facing version like 1.0); fall back to CFBundleVersion
# (the build number), then to a date stamp.
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_SRC/Contents/Info.plist" 2>/dev/null || true)"
if [ -z "$VERSION" ]; then
    VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_SRC/Contents/Info.plist" 2>/dev/null || true)"
fi
if [ -z "$VERSION" ]; then
    VERSION="$VERSION_FALLBACK"
fi

echo "==> Packaging Glotty $VERSION"
STAGE_DIR="$BUILD_DIR/stage"
mkdir -p "$STAGE_DIR"
cp -R "$APP_SRC" "$STAGE_DIR/"
ln -s /Applications "$STAGE_DIR/Applications"

mkdir -p "$DIST_DIR"
DMG_PATH="$DIST_DIR/Glotty-$VERSION.dmg"
rm -f "$DMG_PATH"

echo "==> Creating $DMG_PATH"
hdiutil create \
    -volname "Glotty $VERSION" \
    -srcfolder "$STAGE_DIR" \
    -ov \
    -format UDZO \
    "$DMG_PATH" \
    | tail -5

echo
echo "Done: $DMG_PATH"
ls -lh "$DMG_PATH"
