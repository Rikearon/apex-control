#!/bin/bash
# Build "Apex Control.app" — a self-contained, double-clickable macOS app bundle.
#
#   ./Scripts/build-app.sh [debug|release]        (default: release)
#
# Environment:
#   APEX_UNIVERSAL=1       build arm64 + x86_64 instead of this Mac's architecture only
#   APEX_SIGN_IDENTITY=…   codesign identity, by name or SHA-1 (see "Code signing" below)
#
# The result is build/Apex Control.app. The version comes from
# Sources/ApexKit/Version.swift via Scripts/version.sh.
#
# The typographic quotes in the messages below are deliberate.
# shellcheck disable=SC1111
set -euo pipefail

cd "$(dirname "$0")/.."
CONFIG="${1:-release}"
case "$CONFIG" in
    debug | release) ;;
    *) echo "usage: $0 [debug|release]" >&2; exit 2 ;;
esac

APP_NAME="Apex Control"
BUNDLE_ID="io.github.rikearon.apex-control"
COPYRIGHT="Copyright © 2026 Henrique Aron. Released under the MIT License."
VERSION="$(Scripts/version.sh)"
# CFBundleVersion is a build number: Apple documents it as up to three
# dot-separated integers, so a pre-release suffix (0.2.0-rc.1) stays out of it
# and appears only in CFBundleShortVersionString.
BUNDLE_VERSION="${VERSION%%-*}"
APP_DIR="build/${APP_NAME}.app"

BUILD_ARGS=(-c "$CONFIG")
KIND="$CONFIG"
if [ "${APEX_UNIVERSAL:-}" = "1" ]; then
    BUILD_ARGS+=(--arch arm64 --arch x86_64)
    KIND="$CONFIG, universal"
fi

echo "▸ Building ($KIND)…"
swift build "${BUILD_ARGS[@]}" --product ApexControlApp
# Ask SwiftPM where the product went rather than guessing: the layout differs
# between toolchains, and between single- and multi-architecture builds.
BIN_DIR="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"

echo "▸ Assembling ${APP_DIR}…"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cp "$BIN_DIR/ApexControlApp" "$APP_DIR/Contents/MacOS/${APP_NAME}"

# The licence and the third-party notices travel with the binary, wherever the app is
# dragged to.
cp LICENSE THIRD-PARTY-NOTICES.md "$APP_DIR/Contents/Resources/"

# The icon is optional so a checkout without it still builds.
ICON_KEY=""
if [ -f Resources/AppIcon.icns ]; then
    cp Resources/AppIcon.icns "$APP_DIR/Contents/Resources/AppIcon.icns"
    ICON_KEY="<key>CFBundleIconFile</key><string>AppIcon</string>"
fi

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleVersion</key><string>${BUNDLE_VERSION}</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleExecutable</key><string>${APP_NAME}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    ${ICON_KEY}
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHumanReadableCopyright</key><string>${COPYRIGHT}</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
    <key>NSInputMonitoringUsageDescription</key><string>Apex Control reads which key you press so the Reactive lighting effect can light it up. Nothing you type is written to disk, logged or sent anywhere.</string>
</dict>
</plist>
PLIST
plutil -lint "$APP_DIR/Contents/Info.plist" >/dev/null

# Code signing.
#
# This decides whether permissions survive a rebuild. macOS records a TCC grant
# (Input Monitoring, Accessibility) against the app's code signature, and an
# ad-hoc signature is identified by the hash of the binary itself — so every
# rebuild produces what macOS considers a different app. The old grant stays
# ticked in System Settings and stops working, which is a maddening way to lose
# Reactive lighting.
#
# Signing with a stable certificate fixes it: the grant is then tied to the
# certificate and survives rebuilds. Set APEX_SIGN_IDENTITY to the name of a
# code-signing identity in your keychain, or create one once with
# Scripts/make-signing-identity.sh.
SIGN_IDENTITY="${APEX_SIGN_IDENTITY:-}"
SIGN_LABEL="$SIGN_IDENTITY"
if [ -z "$SIGN_IDENTITY" ]; then
    # Resolve the local identity to its SHA-1: the same certificate can be listed
    # more than once (login and System keychains), and a name that matches twice
    # is ambiguous to codesign. The listing is captured and handed to awk as a
    # here-string rather than piped: an early-exiting reader can SIGPIPE its
    # writer, which `pipefail` (with `set -e`) would turn into a failed build.
    IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"
    SIGN_IDENTITY="$(awk '/"Apex Control Local Signing"/ { print $2; exit }' <<<"$IDENTITIES")"
    SIGN_LABEL="Apex Control Local Signing"
fi

if [ -n "$SIGN_IDENTITY" ]; then
    echo "▸ Code signing as “${SIGN_LABEL}”…"
    codesign --force --deep --options runtime --sign "$SIGN_IDENTITY" "$APP_DIR"
else
    echo "▸ Code signing (ad-hoc)…"
    codesign --force --deep --sign - "$APP_DIR"
    echo "  Signed ad hoc: no “Apex Control Local Signing” identity was found. This only matters"
    echo "  for Reactive lighting. macOS ties its Input Monitoring / Accessibility permission to"
    echo "  the signature, and an ad-hoc signature changes with every build, so each rebuilt app"
    echo "  has to be granted the permission again (remove the old entry with “−” and add the"
    echo "  new one). Run Scripts/make-signing-identity.sh once to keep the grant across rebuilds."
fi

# A bundle whose signature does not verify is killed on launch on Apple Silicon,
# so a failure here should stop the build rather than surface later as a crash.
codesign --verify --deep --strict "$APP_DIR"

echo "✓ Built ${APP_DIR} (version ${VERSION})"
echo "  Run it with:  open \"${APP_DIR}\""
