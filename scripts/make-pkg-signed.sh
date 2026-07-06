#!/usr/bin/env bash
# Build Glotty signed with Developer ID, notarize with Apple, staple
# the ticket, and package into a distributable .pkg INSTALLER.
#
# Output: dist/Glotty-<version>.pkg, signed + notarized + stapled.
#
# Why a .pkg instead of (or alongside) the .dmg:
#   A .pkg is a double-click GUI installer (Next -> Install -> Done).
#   Crucially, Installer.app writes Glotty.app into /Applications
#   ITSELF, and files laid down by an installer payload do NOT get the
#   com.apple.quarantine attribute. So the INSTALLED app is never
#   quarantined -> no "Glotty is damaged / can't be opened" dialog and
#   no "are you sure?" first-launch prompt, even for a non-technical
#   user who received the file zipped through a messenger (Feishu/
#   WeChat). The Gatekeeper check happens ONCE, on the .pkg at install
#   time, and is satisfied offline by the stapled ticket. This is the
#   zero-Terminal alternative to telling users to run
#   `xattr -dr com.apple.quarantine` on a dragged-from-DMG app.
#
# Prerequisites (one-time setup on the build machine):
#   1. A `Developer ID Application` certificate (signs the .app).
#      Verify: security find-identity -v -p codesigning
#         "Developer ID Application: <name> (<team-id>)"
#   2. A `Developer ID Installer` certificate (signs the .pkg wrapper).
#      This is a SEPARATE cert from the Application one above. Create it
#      free at developer.apple.com/account -> Certificates -> + ->
#      "Developer ID Installer". Verify:
#         security find-identity -v
#         "Developer ID Installer: <name> (<team-id>)"
#   3. notarytool credentials stored under profile `glotty-notary`:
#         xcrun notarytool store-credentials "glotty-notary" \
#             --apple-id <apple-id> --team-id <team-id>
#
# Environment overrides (defaults match Glotty's signing identity):
#   SIGN_IDENTITY     — Developer ID Application cert (signs the .app).
#                       Default: "Developer ID Application: Your Name (TEAMID)"
#   INSTALL_IDENTITY  — Developer ID Installer cert (signs the .pkg).
#                       Default: "Developer ID Installer: Your Name (TEAMID)"
#   PKG_IDENTIFIER    — installer package identifier.
#                       Default: com.ruojunye.glotty
#   TEAM_ID           — 10-char team identifier. Default: TEAMID
#   NOTARY_PROFILE    — keychain profile from store-credentials.
#                       Default: glotty-notary

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

SCHEME="Glotty"
CONFIG="Release"
APP_NAME="Glotty.app"
DIST_DIR="$REPO_ROOT/dist"
BUILD_DIR="$(mktemp -d -t glotty-pkg)"
trap 'rm -rf "$BUILD_DIR"' EXIT

SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application: Your Name (TEAMID)}"
INSTALL_IDENTITY="${INSTALL_IDENTITY:-Developer ID Installer: Your Name (TEAMID)}"
PKG_IDENTIFIER="${PKG_IDENTIFIER:-com.ruojunye.glotty}"
TEAM_ID="${TEAM_ID:-TEAMID}"
NOTARY_PROFILE="${NOTARY_PROFILE:-glotty-notary}"
KEYCHAIN_PASS_FILE="${KEYCHAIN_PASS_FILE:-}"
CI_KEYCHAIN_NAME="${CI_KEYCHAIN_NAME:-glotty-ci.keychain-db}"
CODESIGN_KEYCHAIN=""

# CI runs under the CI runner which spawns its own session that can't
# access the user's login keychain even after `unlock-keychain`
# (securityd refuses with errSecAuthFailed when the call comes from a
# non-user-launchd session). The portable fix is a DEDICATED keychain
# for CI signing: one-time setup imports BOTH the Developer ID
# Application AND the Developer ID Installer cert (+ Apple
# intermediates) into it; the workflow unlocks it by name using a
# password stored on the runner (chmod 600 file pointed to by
# KEYCHAIN_PASS_FILE, same pattern as the git token).
#
# Local runs leave KEYCHAIN_PASS_FILE empty and use whatever the
# developer's keychain search path resolves to.
if [ -n "$KEYCHAIN_PASS_FILE" ] && [ -r "$KEYCHAIN_PASS_FILE" ]; then
    REAL_HOME=$(dscl . -read "/Users/$(whoami)" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
    REAL_HOME="${REAL_HOME:-$HOME}"
    CODESIGN_KEYCHAIN="$REAL_HOME/Library/Keychains/$CI_KEYCHAIN_NAME"
    echo "==> Unlocking CI keychain (CI mode)"
    echo "    User: $(whoami)  Keychain: $CODESIGN_KEYCHAIN"
    ls -la "$CODESIGN_KEYCHAIN" 2>&1
    security unlock-keychain -p "$(cat "$KEYCHAIN_PASS_FILE")" "$CODESIGN_KEYCHAIN"
    # Add the CI keychain to the user search list so pkgbuild --sign and
    # notarytool's keychain-profile lookup also resolve. Existing list
    # is preserved so the system keychain still supplies trust anchors.
    EXISTING=$(security list-keychains -d user | tr -d '"' | xargs)
    security list-keychains -d user -s "$CODESIGN_KEYCHAIN" $EXISTING
fi

echo "==> Building $SCHEME ($CONFIG) unsigned"
# Build without code signing first; we re-sign manually below with the
# explicit Developer ID identity and entitlements file. Letting
# xcodebuild sign merges in com.apple.security.get-task-allow=YES from
# a hidden internal default even when CODE_SIGN_ENTITLEMENTS is passed,
# which the notary service rejects. Manual signing gives us one
# predictable codesign invocation with the entitlements we want.
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

echo "==> Signing Glotty.app (Developer ID Application)"
# Single codesign invocation: the bundle has no nested frameworks or
# XPC services. --force replaces xcodebuild's signature, --timestamp
# adds Apple's secure timestamp, --options runtime enables the
# Hardened Runtime (both required by notarytool), --entitlements points
# at our empty file so get-task-allow is NOT requested.
KEYCHAIN_ARGS=()
[ -n "$CODESIGN_KEYCHAIN" ] && KEYCHAIN_ARGS=(--keychain "$CODESIGN_KEYCHAIN")
codesign --force --timestamp --options runtime \
    --sign "$SIGN_IDENTITY" \
    --entitlements "$ENTITLEMENTS_FILE" \
    ${KEYCHAIN_ARGS[@]+"${KEYCHAIN_ARGS[@]}"} \
    "$APP_SRC"

# Resolve version — prefer CFBundleShortVersionString (e.g. 0.1.0),
# fall back to CFBundleVersion, then to a date stamp.
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_SRC/Contents/Info.plist" 2>/dev/null || echo "")"
if [ -z "$VERSION" ]; then
    VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_SRC/Contents/Info.plist" 2>/dev/null || echo "")"
fi
if [ -z "$VERSION" ]; then
    VERSION="$(date +%Y%m%d)"
fi

echo "==> Verifying Glotty.app signature"
codesign --verify --deep --strict --verbose=2 "$APP_SRC"

# notarytool keychain args — used for BOTH the app and the pkg
# submissions below.
NOTARYTOOL_KEYCHAIN_ARGS=()
[ -n "$CODESIGN_KEYCHAIN" ] && NOTARYTOOL_KEYCHAIN_ARGS=(--keychain "$CODESIGN_KEYCHAIN")

# ----------------------------------------------------------------------
# Notarize + STAPLE THE APP ITSELF, before it goes in the pkg.
#
# Even though an installer-deposited app isn't quarantined (so a first
# launch wouldn't normally trigger an online check), stapling the app
# embeds the ticket so the bundle verifies fully OFFLINE no matter how
# it later gets moved or copied. Belt-and-suspenders for CN networks
# where the online notarization check is slow or blocked.
# ----------------------------------------------------------------------
echo "==> Notarizing the app (zip -> notary service)"
echo "    This usually takes 1-3 minutes; can take 10+ on busy days."
APP_ZIP="$BUILD_DIR/Glotty-app.zip"
ditto -c -k --keepParent "$APP_SRC" "$APP_ZIP"
xcrun notarytool submit "$APP_ZIP" \
    --keychain-profile "$NOTARY_PROFILE" \
    ${NOTARYTOOL_KEYCHAIN_ARGS[@]+"${NOTARYTOOL_KEYCHAIN_ARGS[@]}"} \
    --wait

echo "==> Stapling ticket onto Glotty.app (offline-verifiable)"
xcrun stapler staple "$APP_SRC"
xcrun stapler validate "$APP_SRC"

# ----------------------------------------------------------------------
# Build the installer package.
#
# pkgbuild --root maps the contents of a staging dir onto
# --install-location. We stage just Glotty.app so it installs to
# /Applications/Glotty.app. The pkg is signed with the Developer ID
# INSTALLER cert (distinct from the Application cert above); a pkg
# signed with anything else can't be notarized.
#
# We build UNSIGNED with pkgbuild, then sign with `productsign`, NOT
# `pkgbuild --sign`. Reason: pkgbuild has no --keychain flag, so in CI
# it searches keychains ambiguously and blocks on a keychain auth prompt
# that a headless the CI runner session can't answer — the signing hangs
# indefinitely. productsign honors --keychain, pinning the signing
# keychain exactly like the codesign calls above, which signs
# non-interactively. (Diagnosed 2026-06-05 on the runner: pkgbuild
# --sign hung; pkgbuild + productsign --keychain succeeded.)
# ----------------------------------------------------------------------
echo "==> Packaging Glotty $VERSION installer (.pkg)"
STAGE_DIR="$BUILD_DIR/stage"
mkdir -p "$STAGE_DIR"
cp -R "$APP_SRC" "$STAGE_DIR/"

mkdir -p "$DIST_DIR"
PKG_PATH="$DIST_DIR/Glotty-$VERSION.pkg"
rm -f "$PKG_PATH"

echo "==> Building unsigned pkg"
UNSIGNED_PKG="$BUILD_DIR/Glotty-unsigned.pkg"
pkgbuild \
    --root "$STAGE_DIR" \
    --identifier "$PKG_IDENTIFIER" \
    --version "$VERSION" \
    --install-location /Applications \
    "$UNSIGNED_PKG" \
    | tail -5

echo "==> Signing pkg (Developer ID Installer via productsign)"
# KEYCHAIN_ARGS is (--keychain <ci-keychain>) in CI mode, empty locally.
productsign --sign "$INSTALL_IDENTITY" \
    ${KEYCHAIN_ARGS[@]+"${KEYCHAIN_ARGS[@]}"} \
    "$UNSIGNED_PKG" "$PKG_PATH"

echo "==> Notarizing the .pkg"
xcrun notarytool submit "$PKG_PATH" \
    --keychain-profile "$NOTARY_PROFILE" \
    ${NOTARYTOOL_KEYCHAIN_ARGS[@]+"${NOTARYTOOL_KEYCHAIN_ARGS[@]}"} \
    --wait

echo "==> Stapling notarization ticket onto the .pkg"
# Stapling embeds the Apple-issued ticket directly in the .pkg so the
# install verifies OFFLINE — essential on CN networks where the online
# Gatekeeper check is slow or blocked.
xcrun stapler staple "$PKG_PATH"

echo "==> Verifying staple + Gatekeeper (install assessment)"
xcrun stapler validate "$PKG_PATH"
# --type install is the correct assessment type for an installer pkg.
spctl --assess --type install --verbose "$PKG_PATH"
# Also confirm the embedded installer signature chains to Apple.
pkgutil --check-signature "$PKG_PATH" | sed -n '1,12p'

echo
echo "Done: $PKG_PATH"
ls -lh "$PKG_PATH"
