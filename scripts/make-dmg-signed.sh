#!/usr/bin/env bash
# Build Glotty signed with Developer ID, notarize with Apple, staple
# the ticket, and package into a distributable DMG.
#
# Output: dist/Glotty-<version>.dmg, signed + notarized + stapled.
# A user double-clicking this DMG on any Mac will see no Gatekeeper
# warnings — same trust UX as an App Store install.
#
# Prerequisites (one-time setup on the build machine):
#   1. A `Developer ID Application` certificate installed in the
#      login keychain. Verify with:
#         security find-identity -v -p codesigning
#      You should see a line like:
#         "Developer ID Application: <name> (<team-id>)"
#   2. notarytool credentials stored in the keychain under the
#      profile name `glotty-notary`:
#         xcrun notarytool store-credentials "glotty-notary" \
#             --apple-id <apple-id> \
#             --team-id <team-id>
#      (prompts for an app-specific password generated at
#      appleid.apple.com)
#
# Environment overrides (defaults match Glotty's signing identity):
#   SIGN_IDENTITY  — full cert name. Default: "Developer ID
#                    Application: Your Name (TEAMID)"
#   TEAM_ID        — 10-char team identifier. Default: TEAMID
#   NOTARY_PROFILE — keychain profile name from `store-credentials`.
#                    Default: glotty-notary

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

SCHEME="Glotty"
CONFIG="Release"
APP_NAME="Glotty.app"
DIST_DIR="$REPO_ROOT/dist"
BUILD_DIR="$(mktemp -d -t glotty-signed)"
trap 'rm -rf "$BUILD_DIR"' EXIT

SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application: Your Name (TEAMID)}"
TEAM_ID="${TEAM_ID:-TEAMID}"
NOTARY_PROFILE="${NOTARY_PROFILE:-glotty-notary}"
KEYCHAIN_PASS_FILE="${KEYCHAIN_PASS_FILE:-}"
CI_KEYCHAIN_NAME="${CI_KEYCHAIN_NAME:-glotty-ci.keychain-db}"
CODESIGN_KEYCHAIN=""

# CI runs under the CI runner which spawns its own session that can't
# access the user's login keychain even after `unlock-keychain`
# (securityd refuses with errSecAuthFailed when the call comes from
# a non-user-launchd session). The portable fix is a DEDICATED
# keychain for CI signing: one-time setup imports the Developer ID
# cert + intermediates into it; the workflow unlocks it by name
# using a password stored on the runner (chmod 600 file pointed to
# by KEYCHAIN_PASS_FILE, same pattern as the git token).
#
# Local runs leave KEYCHAIN_PASS_FILE empty and use whatever the
# developer's keychain search path resolves to. The codesign call
# below adapts: when CI mode is active, --keychain pins the CI
# keychain; locally, codesign uses the default search path.
if [ -n "$KEYCHAIN_PASS_FILE" ] && [ -r "$KEYCHAIN_PASS_FILE" ]; then
    REAL_HOME=$(dscl . -read "/Users/$(whoami)" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
    REAL_HOME="${REAL_HOME:-$HOME}"
    CODESIGN_KEYCHAIN="$REAL_HOME/Library/Keychains/$CI_KEYCHAIN_NAME"
    echo "==> Unlocking CI keychain (CI mode)"
    echo "    User: $(whoami)  Keychain: $CODESIGN_KEYCHAIN"
    ls -la "$CODESIGN_KEYCHAIN" 2>&1
    security unlock-keychain -p "$(cat "$KEYCHAIN_PASS_FILE")" "$CODESIGN_KEYCHAIN"
    # Add the CI keychain to the user search list so notarytool's
    # keychain-profile lookup also works. The existing list-keychains
    # output is preserved so the system keychain is still searched
    # for trust anchors.
    EXISTING=$(security list-keychains -d user | tr -d '"' | xargs)
    security list-keychains -d user -s "$CODESIGN_KEYCHAIN" $EXISTING
fi

echo "==> Building $SCHEME ($CONFIG) unsigned"
# Build without code signing first; we re-sign manually below with
# the explicit Developer ID identity and entitlements file. Trying
# to let xcodebuild handle the signing led to it merging in
# `com.apple.security.get-task-allow=YES` from a hidden internal
# default even when CODE_SIGN_ENTITLEMENTS was passed on the
# command line — the notary service rejected the resulting binary.
# Signing manually gives us a single, predictable codesign
# invocation with the entitlements file we actually want.
xcodebuild \
    -scheme "$SCHEME" \
    -configuration "$CONFIG" \
    -destination "platform=macOS" \
    -derivedDataPath "$BUILD_DIR/derived" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY="" \
    CODE_SIGN_ENTITLEMENTS="" \
    ENABLE_HARDENED_RUNTIME=YES \
    build \
    | tail -20

APP_SRC="$BUILD_DIR/derived/Build/Products/$CONFIG/$APP_NAME"
if [ ! -d "$APP_SRC" ]; then
    echo "ERROR: built app not found at $APP_SRC"
    exit 1
fi

ENTITLEMENTS_FILE="$REPO_ROOT/Glotty/Glotty-Release.entitlements"

echo "==> Signing Glotty.app"
# Single codesign invocation: the bundle has no nested frameworks,
# helper apps, or XPC services, so there's nothing to sign in
# dependency order — just the top-level .app. Flags:
#   --force         Replace any existing signature from xcodebuild.
#   --timestamp     Apple Secure Timestamp (required by notarytool).
#   --options runtime  Hardened Runtime — required by notarytool.
#   --entitlements <file>  Override Xcode's default entitlements
#       which include `com.apple.security.get-task-allow=YES`. Our
#       file is empty (no special capabilities), which is what we
#       want for a non-sandboxed Developer ID app.
#   --keychain <path>   (CI mode only) Search the CI keychain
#       explicitly for the cert and private key. Local builds skip
#       this flag and use the default search path.
KEYCHAIN_ARGS=()
[ -n "$CODESIGN_KEYCHAIN" ] && KEYCHAIN_ARGS=(--keychain "$CODESIGN_KEYCHAIN")
codesign --force --timestamp --options runtime \
    --sign "$SIGN_IDENTITY" \
    --entitlements "$ENTITLEMENTS_FILE" \
    ${KEYCHAIN_ARGS[@]+"${KEYCHAIN_ARGS[@]}"} \
    "$APP_SRC"

# Resolve version — prefer CFBundleShortVersionString (e.g. 1.0),
# fall back to CFBundleVersion (build number), then to a date stamp.
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_SRC/Contents/Info.plist" 2>/dev/null || echo "")"
if [ -z "$VERSION" ]; then
    VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_SRC/Contents/Info.plist" 2>/dev/null || echo "")"
fi
if [ -z "$VERSION" ]; then
    VERSION="$(date +%Y%m%d)"
fi

echo "==> Verifying Glotty.app signature"
# --deep walks frameworks/dylibs inside the bundle; --strict catches
# common mistakes (unsealed contents, broken nested bundles).
codesign --verify --deep --strict --verbose=2 "$APP_SRC"

# notarytool keychain args — used for BOTH the app and the DMG
# submissions below. In CI mode the credential profile lives in the
# dedicated CI keychain; local runs leave it on the default search.
NOTARYTOOL_KEYCHAIN_ARGS=()
[ -n "$CODESIGN_KEYCHAIN" ] && NOTARYTOOL_KEYCHAIN_ARGS=(--keychain "$CODESIGN_KEYCHAIN")

# ----------------------------------------------------------------------
# Notarize + STAPLE THE APP ITSELF, before it goes in the DMG.
#
# Stapling the DMG alone is NOT enough: when the user mounts the DMG
# and copies Glotty.app to /Applications, the extracted app carries no
# stapled ticket, so Gatekeeper falls back to an ONLINE check with
# Apple on first launch. That online check is slow or blocked on some
# networks (notably mainland China), where it manifests as "Glotty is
# damaged / can't be opened". Stapling the app embeds the ticket so
# the launch verifies fully OFFLINE. (Diagnosed 2026-06-04: a user in
# CN couldn't open the downloaded build; the SSH-copied build worked
# only because scp strips the quarantine flag.)
# ----------------------------------------------------------------------
echo "==> Notarizing the app (zip → notary service)"
echo "    This usually takes 1-3 minutes; can take 10+ on busy days."
APP_ZIP="$BUILD_DIR/Glotty-app.zip"
# `ditto -c -k --keepParent` makes the zip notarytool expects.
ditto -c -k --keepParent "$APP_SRC" "$APP_ZIP"
xcrun notarytool submit "$APP_ZIP" \
    --keychain-profile "$NOTARY_PROFILE" \
    ${NOTARYTOOL_KEYCHAIN_ARGS[@]+"${NOTARYTOOL_KEYCHAIN_ARGS[@]}"} \
    --wait

echo "==> Stapling ticket onto Glotty.app (offline-verifiable)"
xcrun stapler staple "$APP_SRC"
xcrun stapler validate "$APP_SRC"

echo "==> Packaging Glotty $VERSION"
STAGE_DIR="$BUILD_DIR/stage"
mkdir -p "$STAGE_DIR"
# Copy the now-STAPLED app into the DMG.
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

echo "==> Signing DMG"
# DMG itself also needs to be signed + timestamped so Gatekeeper
# trusts the download before it's mounted. Hardened Runtime doesn't
# apply to disk images (no executable), so --options runtime is
# omitted here.
codesign --force --timestamp \
    --sign "$SIGN_IDENTITY" \
    ${KEYCHAIN_ARGS[@]+"${KEYCHAIN_ARGS[@]}"} \
    "$DMG_PATH"

echo "==> Notarizing the DMG"
xcrun notarytool submit "$DMG_PATH" \
    --keychain-profile "$NOTARY_PROFILE" \
    ${NOTARYTOOL_KEYCHAIN_ARGS[@]+"${NOTARYTOOL_KEYCHAIN_ARGS[@]}"} \
    --wait

echo "==> Stapling notarization ticket onto DMG"
# Stapling embeds the Apple-issued ticket directly in the DMG so the
# DOWNLOAD itself verifies offline. Combined with the stapled app
# above, both the .dmg and the extracted .app are fully offline-clean.
xcrun stapler staple "$DMG_PATH"

echo "==> Verifying staples + Gatekeeper"
xcrun stapler validate "$DMG_PATH"
spctl --assess --type install --verbose "$DMG_PATH"
# Also assert the app inside is stapled (the thing that was missing).
MNT_CHECK=$(hdiutil attach "$DMG_PATH" -nobrowse -noautoopen 2>/dev/null | grep -oE "/Volumes/.*" | head -1)
if [ -n "$MNT_CHECK" ]; then
    xcrun stapler validate "$MNT_CHECK/Glotty.app" || echo "WARN: app inside DMG not stapled"
    hdiutil detach "$MNT_CHECK" -quiet 2>/dev/null || true
fi

echo
echo "Done: $DMG_PATH"
ls -lh "$DMG_PATH"
