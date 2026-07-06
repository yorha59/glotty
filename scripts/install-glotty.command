#!/bin/bash
# Glotty Installer - removes macOS quarantine and installs to /Applications
# Usage: double-click this file in Finder, or run: bash install-glotty.command
cd "$(dirname "$0")"

echo "==> Installing Glotty..."

# Find the app ZIP
ZIP=$(ls Glotty-*.zip 2>/dev/null | head -1)
if [ -z "$ZIP" ]; then
    echo "ERROR: Glotty-*.zip not found in $(pwd)"
    echo "Please make sure the ZIP file is in the same folder as this script."
    read -p "Press Enter to close..."
    exit 1
fi

echo "    Found: $ZIP"

# Extract to temp directory
TMPDIR=$(mktemp -d)
ditto -x -k "$ZIP" "$TMPDIR"

# Clear quarantine (critical — Feishu/WeChat downloads get flagged)
xattr -cr "$TMPDIR/Glotty.app"

# Copy to Applications
echo "    Copying to /Applications..."
rm -rf /Applications/Glotty.app 2>/dev/null
cp -R "$TMPDIR/Glotty.app" /Applications/

# Cleanup
rm -rf "$TMPDIR"

echo ""
echo "✅ Glotty installed successfully!"
echo "    You can find it in /Applications or Launchpad."
echo ""

# Launch
open /Applications/Glotty.app 2>/dev/null

read -p "Press Enter to close..."
