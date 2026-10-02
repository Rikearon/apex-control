#!/bin/bash
# Produce the release artefacts in dist/:
#
#   ApexControl-<version>.dmg        the app (universal), next to an /Applications shortcut
#   apexctl-<version>-macos.zip      the command-line tool (universal)
#   SHA256SUMS                       checksums of both
#
# This is exactly what the release workflow runs, so a maintainer can reproduce
# a release locally with `make package`. Every artefact is checked before the
# script reports success: architectures, signature, disk image, checksums, and
# that the binary reports the version the artefacts are named after.
#
# Signing: the app follows build-app.sh (ad-hoc, unless a signing identity is
# available); apexctl is ad-hoc unless APEX_SIGN_IDENTITY is set. Neither is
# notarised, so Gatekeeper asks the user to approve the app once — see the
# README and docs/MAINTAINING.md.
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="$(Scripts/version.sh)"
DIST="$(pwd)/dist"
DMG="ApexControl-${VERSION}.dmg"
CLI_ZIP="apexctl-${VERSION}-macos.zip"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

# The artefacts are assembled in $OUT and replace dist/ only after every check
# has passed, so a failed run leaves the previous dist/ untouched.
OUT="$STAGE/dist"
mkdir -p "$OUT"

# Both slices, or the artefact is not what the README promises. Each is checked
# on its own: the two names share a separating space in `lipo`'s output, so a
# single pattern for "both" cannot match it.
require_universal() {
    local archs slice
    archs=" $(lipo -archs "$1") "
    for slice in arm64 x86_64; do
        case "$archs" in
            *" $slice "*) ;;
            *) echo "error: $1 has no $slice slice (has:$archs)" >&2; exit 1 ;;
        esac
    done
}

echo "▸ Building the app (universal)…"
APEX_UNIVERSAL=1 Scripts/build-app.sh release
APP="build/Apex Control.app"
require_universal "$APP/Contents/MacOS/Apex Control"

echo "▸ Building apexctl (universal)…"
CLI_ARGS=(-c release --arch arm64 --arch x86_64)
swift build "${CLI_ARGS[@]}" --product apexctl
CLI_BIN="$(swift build "${CLI_ARGS[@]}" --show-bin-path)/apexctl"
require_universal "$CLI_BIN"

echo "▸ Packaging apexctl…"
mkdir -p "$STAGE/cli"
cp "$CLI_BIN" "$STAGE/cli/apexctl"
cp LICENSE THIRD-PARTY-NOTICES.md "$STAGE/cli/"
# SwiftPM leaves a linker signature on each slice; re-sign the merged binary so
# it carries one signature over the whole file (arm64 refuses unsigned code).
codesign --force --sign "${APEX_SIGN_IDENTITY:--}" "$STAGE/cli/apexctl"
codesign --verify --strict "$STAGE/cli/apexctl"
(cd "$STAGE/cli" && zip -q -X "$OUT/$CLI_ZIP" apexctl LICENSE THIRD-PARTY-NOTICES.md)

echo "▸ Packaging the disk image…"
mkdir -p "$STAGE/dmg"
ditto "$APP" "$STAGE/dmg/Apex Control.app"
ln -s /Applications "$STAGE/dmg/Applications"
cp LICENSE THIRD-PARTY-NOTICES.md "$STAGE/dmg/"
# `hdiutil create` occasionally fails with "Resource busy" on CI runners; it is
# transient, so retry rather than fail a release over it.
attempt=1
until hdiutil create -quiet -volname "Apex Control" -srcfolder "$STAGE/dmg" \
        -fs HFS+ -format UDZO -ov "$OUT/$DMG"; do
    if [ "$attempt" -ge 3 ]; then
        echo "error: hdiutil create failed $attempt times" >&2
        exit 1
    fi
    attempt=$((attempt + 1))
    echo "  hdiutil create failed; retrying ($attempt/3)…" >&2
    sleep 5
done
hdiutil verify -quiet "$OUT/$DMG"

echo "▸ Checksums…"
(cd "$OUT" && shasum -a 256 "$DMG" "$CLI_ZIP" > SHA256SUMS && shasum -a 256 -c SHA256SUMS)

echo "▸ Checking the packaged CLI reports version ${VERSION}…"
mkdir -p "$STAGE/unzip"
unzip -q "$OUT/$CLI_ZIP" -d "$STAGE/unzip"
REPORTED="$("$STAGE/unzip/apexctl" --version)"
if [ "$REPORTED" != "apexctl ${VERSION}" ]; then
    echo "error: packaged apexctl says '${REPORTED}', expected 'apexctl ${VERSION}'" >&2
    exit 1
fi

rm -rf "$DIST"
mv "$OUT" "$DIST"

echo "✓ Release artefacts for ${VERSION} are in dist/"
ls -l "$DIST"
