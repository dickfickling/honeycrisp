#!/usr/bin/env bash
# Build Honeycrisp and assemble it into a signed .app bundle in dist/.
#
# Usage:
#   Scripts/make-app.sh              Dev build: ad-hoc signed, current arch.
#   Scripts/make-app.sh --release    Distribution build: universal binary,
#                                    Developer ID + hardened runtime,
#                                    notarized + stapled, zipped for upload.
#
# Release-mode configuration (environment variables):
#   SIGN_IDENTITY   codesign identity (default: "Developer ID Application",
#                   which substring-matches the cert in your keychain)
#   NOTARY_PROFILE  notarytool keychain profile (default: honeycrisp-notary);
#                   create once with:
#                     xcrun notarytool store-credentials honeycrisp-notary \
#                       --apple-id you@example.com --team-id TEAMID \
#                       --password <app-specific password>
#   VERSION         marketing + build version (default: 0.1.0)
#   SKIP_NOTARIZE=1 sign with Developer ID but skip notarization/stapling
#                   (for testing the signing pipeline)
#
# Idempotent: safe to re-run.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

RELEASE=0
if [[ "${1:-}" == "--release" ]]; then
    RELEASE=1
fi

APP_NAME="Honeycrisp"
BUNDLE_ID="us.fickling.honeycrisp2"
VERSION="${VERSION:-0.1.0}"
MIN_OS="14.0"
DIST_DIR="dist"
APP_DIR="${DIST_DIR}/${APP_NAME}.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"
NOTARY_PROFILE="${NOTARY_PROFILE:-honeycrisp-notary}"

if [[ ${RELEASE} -eq 1 ]]; then
    # Fail early, before a long build, if the signing identity is absent.
    if ! security find-identity -v -p codesigning | grep -q "${SIGN_IDENTITY}"; then
        echo "error: no codesigning identity matching \"${SIGN_IDENTITY}\" in the keychain." >&2
        echo "Direct distribution needs a Developer ID Application certificate:" >&2
        echo "  https://developer.apple.com/account/resources/certificates/add" >&2
        echo "(Apple Development / Apple Distribution certs won't pass Gatekeeper.)" >&2
        exit 1
    fi
    echo "==> Building ${APP_NAME} ${VERSION} (release, universal)"
    swift build -c release --arch arm64 --arch x86_64
    BIN_PATH="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/${APP_NAME}"
else
    echo "==> Building ${APP_NAME} (release, current arch)"
    swift build -c release
    BIN_PATH="$(swift build -c release --show-bin-path)/${APP_NAME}"
fi

echo "==> Assembling ${APP_DIR}"
rm -rf "${DIST_DIR}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"

cp "${BIN_PATH}" "${MACOS_DIR}/${APP_NAME}"

# Ship the third-party attributions inside the bundle so the MIT notices
# (pyatv, BigInt) travel with the distributed binary, not just the repo.
cp THIRD-PARTY-LICENSES.md "${RESOURCES_DIR}/THIRD-PARTY-LICENSES.md"

echo "==> Generating app icon"
ICONSET_DIR="${DIST_DIR}/${APP_NAME}.iconset"
mkdir -p "${ICONSET_DIR}"
for size in 16 32 128 256 512; do
    sips -z "${size}" "${size}" Assets/icon.png \
        --out "${ICONSET_DIR}/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "${double}" "${double}" Assets/icon.png \
        --out "${ICONSET_DIR}/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "${ICONSET_DIR}" -o "${RESOURCES_DIR}/AppIcon.icns"
rm -rf "${ICONSET_DIR}"

cat > "${CONTENTS_DIR}/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key>
    <string>${MIN_OS}</string>
    <key>LSUIElement</key>
    <false/>
    <key>NSLocalNetworkUsageDescription</key>
    <string>Honeycrisp discovers and controls Apple TVs on your local network.</string>
    <key>NSBonjourServices</key>
    <array>
        <string>_companion-link._tcp</string>
    </array>
</dict>
</plist>
PLIST

if [[ ${RELEASE} -eq 0 ]]; then
    echo "==> Code signing (ad-hoc)"
    codesign --force --sign - --deep "${APP_DIR}"
    echo "==> Done: ${APP_DIR}"
    exit 0
fi

echo "==> Code signing (${SIGN_IDENTITY}, hardened runtime)"
codesign --force --options runtime --timestamp \
    --sign "${SIGN_IDENTITY}" "${APP_DIR}"
codesign --verify --strict --verbose=2 "${APP_DIR}"

ZIP_PATH="${DIST_DIR}/${APP_NAME}-${VERSION}.zip"

if [[ "${SKIP_NOTARIZE:-0}" == "1" ]]; then
    echo "==> Skipping notarization (SKIP_NOTARIZE=1)"
else
    echo "==> Notarizing (profile: ${NOTARY_PROFILE})"
    ditto -c -k --keepParent "${APP_DIR}" "${DIST_DIR}/notarize-upload.zip"
    if ! xcrun notarytool submit "${DIST_DIR}/notarize-upload.zip" \
        --keychain-profile "${NOTARY_PROFILE}" --wait; then
        echo "error: notarization failed. If the profile is missing, create it with:" >&2
        echo "  xcrun notarytool store-credentials ${NOTARY_PROFILE} \\" >&2
        echo "    --apple-id <apple-id> --team-id <team-id> --password <app-specific-password>" >&2
        exit 1
    fi
    rm -f "${DIST_DIR}/notarize-upload.zip"
    echo "==> Stapling notarization ticket"
    xcrun stapler staple "${APP_DIR}"
    echo "==> Gatekeeper check"
    spctl --assess --type execute --verbose=2 "${APP_DIR}"
fi

echo "==> Packaging ${ZIP_PATH}"
ditto -c -k --keepParent "${APP_DIR}" "${ZIP_PATH}"

echo "==> Done: ${APP_DIR}"
echo "    Upload:  ${ZIP_PATH}"
