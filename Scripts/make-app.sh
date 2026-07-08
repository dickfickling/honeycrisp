#!/usr/bin/env bash
# Build Honeycrisp in release mode and assemble it into a signed .app bundle
# in dist/Honeycrisp.app. Idempotent: safe to re-run.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

APP_NAME="Honeycrisp"
BUNDLE_ID="us.fickling.honeycrisp2"
VERSION="0.1.0"
MIN_OS="14.0"
DIST_DIR="dist"
APP_DIR="${DIST_DIR}/${APP_NAME}.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

echo "==> Building ${APP_NAME} (release)"
swift build -c release

echo "==> Assembling ${APP_DIR}"
rm -rf "${DIST_DIR}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"

BIN_PATH="$(swift build -c release --show-bin-path)/${APP_NAME}"
cp "${BIN_PATH}" "${MACOS_DIR}/${APP_NAME}"

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

echo "==> Code signing (ad-hoc)"
codesign --force --sign - --deep "${APP_DIR}"

echo "==> Done: ${APP_DIR}"
