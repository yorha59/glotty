#!/usr/bin/env bash
# Only run on a fresh signing runner, after the unsigned artifact is downloaded.
# Cleanup completes before this script returns, including on failure/cancellation.
set +x
set -euo pipefail
umask 077

: "${RUNNER_TEMP:?RUNNER_TEMP is required}"
: "${PREBUILT_APP_PATH:?PREBUILT_APP_PATH is required}"
: "${MACOS_SIGNING_P12_BASE64:?Missing environment signing certificate}"
: "${MACOS_INSTALLER_P12_BASE64:?Missing environment installer certificate}"
: "${MACOS_SIGNING_P12_PASSWORD:?Missing environment P12 password}"
: "${APPLE_ID:?Missing environment Apple ID}"
: "${APPLE_APP_SPECIFIC_PASSWORD:?Missing environment notary password}"
if [ ! -d "$PREBUILT_APP_PATH" ]; then
    echo "ERROR: prebuilt app not found" >&2
    exit 1
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ORIGINAL_KEYCHAINS=()
ORIGINAL_KEYCHAIN_LIST="$(security list-keychains -d user)"
while IFS= read -r line; do
    [ -z "$line" ] && continue
    line="${line#*\"}"
    line="${line%\"*}"
    ORIGINAL_KEYCHAINS+=("$line")
done <<< "$ORIGINAL_KEYCHAIN_LIST"

SECRET_DIR="$(mktemp -d "$RUNNER_TEMP/glotty-signing.XXXXXX")"
KC="$SECRET_DIR/signing.keychain-db"
cleanup() {
    local status=$?
    trap - EXIT
    if [ -f "$KC" ]; then
        security delete-keychain "$KC" >/dev/null 2>&1 || status=1
    fi
    security list-keychains -d user -s ${ORIGINAL_KEYCHAINS[@]+"${ORIGINAL_KEYCHAINS[@]}"} >/dev/null 2>&1 || status=1
    rm -rf "$SECRET_DIR" || status=1
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Use a separate random keychain password; never persist the P12 password.
KC_PASSWORD="$(openssl rand -hex 32)"
printf '::add-mask::%s\n' "$KC_PASSWORD"
printf '%s' "$MACOS_SIGNING_P12_BASE64" | base64 --decode > "$SECRET_DIR/app.p12"
printf '%s' "$MACOS_INSTALLER_P12_BASE64" | base64 --decode > "$SECRET_DIR/installer.p12"
security create-keychain -p "$KC_PASSWORD" "$KC"
security set-keychain-settings -lut 5400 "$KC"
security unlock-keychain -p "$KC_PASSWORD" "$KC"
# -x makes private keys non-extractable. Do not trust /usr/bin/security for use.
security import "$SECRET_DIR/app.p12" -k "$KC" -x \
    -P "$MACOS_SIGNING_P12_PASSWORD" -T /usr/bin/codesign -T /usr/bin/productsign
security import "$SECRET_DIR/installer.p12" -k "$KC" -x \
    -P "$MACOS_SIGNING_P12_PASSWORD" -T /usr/bin/codesign -T /usr/bin/productsign
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KC_PASSWORD" "$KC" >/dev/null
security list-keychains -d user -s "$KC" ${ORIGINAL_KEYCHAINS[@]+"${ORIGINAL_KEYCHAINS[@]}"}
xcrun notarytool store-credentials glotty-notary \
    --apple-id "$APPLE_ID" --password "$APPLE_APP_SPECIFIC_PASSWORD" \
    --team-id 47D8DFFZQ4 --keychain "$KC"
rm -f "$SECRET_DIR/app.p12" "$SECRET_DIR/installer.p12"
unset MACOS_SIGNING_P12_BASE64 MACOS_INSTALLER_P12_BASE64 MACOS_SIGNING_P12_PASSWORD
unset APPLE_ID APPLE_APP_SPECIFIC_PASSWORD KC_PASSWORD KEYCHAIN_PASS_FILE

# This path never invokes xcodebuild, XcodeGen, or package build plugins.
CODESIGN_KEYCHAIN="$KC" bash "$REPO_ROOT/scripts/make-pkg-signed.sh"
