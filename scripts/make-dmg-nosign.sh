#!/usr/bin/env bash
# Build Glotty DMG without code signing (for CI)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

# Find the built app
APP_SRC=$(find ~/Library/Developer/Xcode/DerivedData -name "Glotty.app" -path "*/Release/*" 2>/dev/null | head -1)
if [ -z "$APP_SRC" ]; then
    echo "ERROR: Glotty.app not found in DerivedData"
    exit 1
fi

VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_SRC/Contents/Info.plist" 2>/dev/null || date +%Y%m%d)

echo "==> Packaging Glotty $VERSION"
STAGE_DIR=$(mktemp -d -t glotty-stage)
cp -R "$APP_SRC" "$STAGE_DIR/"
ln -s /Applications "$STAGE_DIR/Applications"

DIST_DIR="$REPO_ROOT/dist"
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

rm -rf "$STAGE_DIR"
echo ""
echo "Done: $DMG_PATH"
ls -lh "$DMG_PATH"
