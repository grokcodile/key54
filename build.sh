#!/bin/bash
# Builds Key54.app into ./build. Used by both install.sh and CI.
#
# Optional code-signing: set SIGN_IDENTITY to a "Developer ID Application: …"
# identity to sign for distribution; otherwise an ad-hoc signature is used.
set -e

cd "$(dirname "$0")"

APP_NAME="Key54"
BUILD_DIR="./build/${APP_NAME}.app"
SIGN_IDENTITY="${SIGN_IDENTITY:-}"

echo "Building ${APP_NAME}..."

rm -rf ./build
mkdir -p "${BUILD_DIR}/Contents/MacOS"
mkdir -p "${BUILD_DIR}/Contents/Resources"

# Icon — generate the full iconset from make_icon.swift,
# then quantize + pack into .icns.
rm -rf AppIcon.iconset
swift make_icon.swift AppIcon.iconset
# Lossy-quantize the PNGs to shrink the final .icns (iconutil re-encodes,
# so only reduced color complexity survives — lossless passes don't help).
if command -v pngquant >/dev/null 2>&1; then
    pngquant --quality=70-95 --speed 1 --ext .png --force AppIcon.iconset/*.png || true
fi
iconutil -c icns AppIcon.iconset -o AppIcon.icns
cp "AppIcon.icns" "${BUILD_DIR}/Contents/Resources/AppIcon.icns"

# Developer headshot for the Tip Jar popover (optional — shows a placeholder
# circle if absent). 128 px HEIC, ~7 KB.
[ -f headshot.heic ] && cp headshot.heic "${BUILD_DIR}/Contents/Resources/headshot.heic"

# Explicit deployment target: keeps the binary runnable on macOS 13+ even when
# built with a newer SDK (Liquid Glass APIs are weak-linked and runtime-gated).
swiftc -O main.swift \
    -target "$(uname -m)-apple-macos13.0" \
    -framework Cocoa \
    -framework ServiceManagement \
    -o "${BUILD_DIR}/Contents/MacOS/${APP_NAME}"

cp Info.plist "${BUILD_DIR}/Contents/Info.plist"

if [ -n "$SIGN_IDENTITY" ]; then
    echo "Signing with: ${SIGN_IDENTITY}"
    codesign --force --options runtime --timestamp \
        --entitlements Key54.entitlements \
        --sign "$SIGN_IDENTITY" "${BUILD_DIR}"
else
    codesign --force --deep --sign - "${BUILD_DIR}"
fi

echo "Built ${BUILD_DIR}"
