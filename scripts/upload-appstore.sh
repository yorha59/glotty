#!/usr/bin/env bash
# Build Glotty signed for Mac App Store distribution, upload to
# App Store Connect for review.
#
# Output: build/Glotty.xcarchive (archive on disk) and an uploaded
# binary in App Store Connect under the same bundle ID. The first
# successful upload is what we use to learn whether Apple's
# automated review accepts Glotty's current code (in particular
# the Dictionary Services dlsym calls and the Fn-leader CGEventTap).
#
# Prerequisites — see doc/app-store-submission.md for details:
#   1. An `Apple Distribution` certificate in the keychain (not
#      Developer ID — those are different):
#         security find-identity -v -p codesigning
#         # Should show "Apple Distribution: Your Name (TEAMID)"
#   2. An App Store Connect record for the bundle ID at
#      appstoreconnect.apple.com (Apps -> + -> New App).
#   3. A Mac App Store provisioning profile downloaded from
#      developer.apple.com and either: installed in
#      ~/Library/MobileDevice/Provisioning Profiles/, OR pointed at
#      by the PROVISIONING_PROFILE env var below.
#   4. An App Store Connect API key (.p8 file + Key ID + Issuer ID).
#      Generated at appstoreconnect.apple.com -> Users and Access ->
#      Keys -> App Store Connect API. Store as ~/Library/MobileDevice/
#      AppStoreConnect_AuthKey_<KEY_ID>.p8.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

SCHEME="Glotty"
CONFIG="Release"
ARCHIVE_PATH="$REPO_ROOT/build/Glotty.xcarchive"
EXPORT_PATH="$REPO_ROOT/build/AppStoreExport"
EXPORT_OPTIONS_PLIST="$REPO_ROOT/build/exportOptions.plist"

SIGN_IDENTITY="${SIGN_IDENTITY:-Apple Distribution: Your Name (TEAMID)}"
TEAM_ID="${TEAM_ID:-TEAMID}"
BUNDLE_ID="${BUNDLE_ID:-com.ruojunye.glotty}"
# Name of the provisioning profile created by appstore-bootstrap.py.
# Must match the `PROFILE_NAME` constant in that script.
PROVISIONING_PROFILE_SPECIFIER="${PROVISIONING_PROFILE_SPECIFIER:-Glotty Mac App Store}"
APPSTORE_ENTITLEMENTS="$REPO_ROOT/Glotty/Glotty-AppStore.entitlements"

# App Store Connect API key for upload. Set these via env or
# provide a .env.appstore file next to this script that sources them.
# The .p8 file's standard location is
# ~/Library/MobileDevice/AppStoreConnect_AuthKey_<KEY_ID>.p8 —
# `xcrun altool` finds it there automatically when --apiKey + --apiIssuer
# are provided.
APP_STORE_KEY_ID="${APP_STORE_KEY_ID:-}"
APP_STORE_ISSUER_ID="${APP_STORE_ISSUER_ID:-}"

if [ -f "$REPO_ROOT/.env.appstore" ]; then
    set -a
    # shellcheck disable=SC1091
    . "$REPO_ROOT/.env.appstore"
    set +a
fi

if [ -z "$APP_STORE_KEY_ID" ] || [ -z "$APP_STORE_ISSUER_ID" ]; then
    echo "ERROR: APP_STORE_KEY_ID and APP_STORE_ISSUER_ID must be set."
    echo "Either export them in your shell or create $REPO_ROOT/.env.appstore with:"
    echo "  APP_STORE_KEY_ID=ABCD123456"
    echo "  APP_STORE_ISSUER_ID=00000000-0000-0000-0000-000000000000"
    echo "Find these at appstoreconnect.apple.com -> Users and Access -> Keys."
    exit 1
fi

echo "==> Cleaning previous build"
rm -rf "$REPO_ROOT/build"
mkdir -p "$REPO_ROOT/build"

# Generate the exportOptions.plist used by `xcodebuild -exportArchive`.
# `method=app-store-connect` produces the .pkg shape App Store Connect
# expects; `signingStyle=automatic` lets Xcode pick the matching
# provisioning profile from those installed in
# ~/Library/MobileDevice/Provisioning Profiles/.
cat > "$EXPORT_OPTIONS_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store-connect</string>
    <key>destination</key>
    <string>upload</string>
    <key>teamID</key>
    <string>$TEAM_ID</string>
    <key>signingStyle</key>
    <string>manual</string>
    <key>signingCertificate</key>
    <string>Apple Distribution</string>
    <!--
        Mac App Store uploads need a separate cert to sign the .pkg
        installer that Xcode wraps the .app in. The installer cert's
        display name is "3rd Party Mac Developer Installer" (legacy
        branding; Apple's API calls it "Mac Installer Distribution").
    -->
    <key>installerSigningCertificate</key>
    <string>3rd Party Mac Developer Installer</string>
    <key>provisioningProfiles</key>
    <dict>
        <key>$BUNDLE_ID</key>
        <string>$PROVISIONING_PROFILE_SPECIFIER</string>
    </dict>
    <key>uploadSymbols</key>
    <true/>
</dict>
</plist>
EOF

echo "==> Archiving $SCHEME ($CONFIG) for App Store"
echo "    Bundle ID: $BUNDLE_ID"
echo "    Identity:  $SIGN_IDENTITY"
echo "    Sandbox:   enabled via Glotty-AppStore.entitlements"
# Force the App Store entitlements file. The default for the project
# is Glotty-Release.entitlements (used by Developer ID); this
# overrides it for the archive build only.
# Manual signing: project.yml has CODE_SIGN_STYLE=Automatic for local
# dev, but for the App Store archive we override to Manual and point
# at the specific Distribution identity + provisioning profile. Xcode
# refuses to mix Automatic with an explicit CODE_SIGN_IDENTITY.
xcodebuild archive \
    -scheme "$SCHEME" \
    -configuration "$CONFIG" \
    -destination "generic/platform=macOS" \
    -archivePath "$ARCHIVE_PATH" \
    PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
    CODE_SIGN_STYLE=Manual \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
    PROVISIONING_PROFILE_SPECIFIER="$PROVISIONING_PROFILE_SPECIFIER" \
    CODE_SIGN_ENTITLEMENTS="$APPSTORE_ENTITLEMENTS" \
    ENABLE_HARDENED_RUNTIME=YES \
    OTHER_CODE_SIGN_FLAGS="--timestamp" \
    | tail -25

echo "==> Exporting + uploading to App Store Connect"
# `destination: upload` in exportOptions.plist means xcodebuild does
# the upload itself via Transporter, no separate altool call needed.
# This is what catches the local validator errors (private API,
# missing entitlements, malformed binary). If this command exits 0,
# the build reached App Store Connect and Apple's automated review
# starts within ~30 minutes.
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_PATH" \
    -exportOptionsPlist "$EXPORT_OPTIONS_PLIST" \
    -authenticationKeyIssuerID "$APP_STORE_ISSUER_ID" \
    -authenticationKeyID "$APP_STORE_KEY_ID" \
    -authenticationKeyPath "$HOME/Library/MobileDevice/AppStoreConnect_AuthKey_$APP_STORE_KEY_ID.p8" \
    | tail -30

echo
echo "Done. Check appstoreconnect.apple.com -> Apps -> Glotty -> TestFlight"
echo "or App Store tab for the new build (usually appears within 5-30"
echo "minutes after upload). If automated review finds issues you'll get"
echo "an email; otherwise the build becomes available for manual review"
echo "submission once processing completes."
