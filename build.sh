#!/bin/bash
# Builds Trapdoor.app into ./build. Used by both install.sh and CI.
#
# Optional code-signing: set SIGN_IDENTITY to a "Developer ID Application: …"
# identity to sign for distribution; otherwise an ad-hoc signature is used.
set -e

cd "$(dirname "$0")"

APP_NAME="Trapdoor"
BUILD_DIR="./build/${APP_NAME}.app"
SRC_ICON="trapdoor_icon.png"
SIGN_IDENTITY="${SIGN_IDENTITY:-}"

echo "Building ${APP_NAME}..."

rm -rf ./build
mkdir -p "${BUILD_DIR}/Contents/MacOS"
mkdir -p "${BUILD_DIR}/Contents/Resources"

# Icon — regenerate from source PNG (Core Graphics resize, preserves alpha)
if [ -f "$SRC_ICON" ]; then
    rm -rf AppIcon.iconset
    swift make_iconset.swift "$SRC_ICON" AppIcon.iconset
    # Lossy-quantize the PNGs to shrink the final .icns (iconutil re-encodes,
    # so only reduced color complexity survives — lossless passes don't help).
    if command -v pngquant >/dev/null 2>&1; then
        pngquant --quality=70-95 --speed 1 --ext .png --force AppIcon.iconset/*.png || true
    fi
    iconutil -c icns AppIcon.iconset -o AppIcon.icns
fi
if [ -f "AppIcon.icns" ]; then
    cp "AppIcon.icns" "${BUILD_DIR}/Contents/Resources/AppIcon.icns"
fi

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
        --entitlements Trapdoor.entitlements \
        --sign "$SIGN_IDENTITY" "${BUILD_DIR}"
else
    codesign --force --deep --sign - "${BUILD_DIR}"
fi

echo "Built ${BUILD_DIR}"
