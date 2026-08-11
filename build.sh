#!/bin/bash
# Builds Key54.app into ./build. Used by both install.sh and CI.
#
# Code-signing: set SIGN_IDENTITY to a "Developer ID Application: …" identity to
# force one; otherwise the first Developer ID in the keychain is used, and only a
# machine without one falls back to ad-hoc.
#
# The fallback matters for more than distribution. macOS keys the Accessibility
# grant to the app's designated requirement — with a Developer ID that's the
# stable "identifier + team certificate", but an ad-hoc signature has no cert, so
# it reduces to the binary's cdhash. That changes on *every* build, so each
# reinstall looks like a brand-new app and has to be re-granted Accessibility.
set -e

cd "$(dirname "$0")"

APP_NAME="Key54"
BUILD_DIR="./build/${APP_NAME}.app"
SIGN_IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
    | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)"/\1/')}"

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

# Explicit deployment target: keeps the binary runnable on macOS 13+ even when
# built with a newer SDK (Liquid Glass APIs are weak-linked and runtime-gated).
# -Osize rather than -O, as in Pullcord: this app sits idle on a flagsChanged
# event tap, and the one thing that isn't idle — the HUD — animates on the render
# server via CALayer rather than here. Size is worth more than the last few
# percent of throughput. -Osize barely moves the binary on its own (315KB → 313KB)
# but it emits fewer specializations, so it strips 16KB smaller than -O does.
swiftc -Osize main.swift \
    -target "$(uname -m)-apple-macos13.0" \
    -framework Cocoa \
    -framework ServiceManagement \
    -o "${BUILD_DIR}/Contents/MacOS/${APP_NAME}"

# Local symbols are a third of the binary and nothing reads them at runtime —
# Swift reflection uses its own metadata sections (__swift5_typeref, _fieldmd,
# _reflstr, _proto), which strip -x leaves alone. Measured: 313KB down to 200KB.
# Has to happen before codesign, or it breaks the signature.
# (-x keeps global symbols; a full strip can break Swift binaries.)
strip -x "${BUILD_DIR}/Contents/MacOS/${APP_NAME}"

cp Info.plist "${BUILD_DIR}/Contents/Info.plist"

if [ -n "$SIGN_IDENTITY" ]; then
    echo "Signing with: ${SIGN_IDENTITY}"
    # --options runtime is the hardened runtime, which notarization requires.
    # --timestamp gets a trusted timestamp, so the signature outlives the cert.
    codesign --force --options runtime --timestamp \
        --sign "$SIGN_IDENTITY" "${BUILD_DIR}"
    codesign --verify --strict --verbose=1 "${BUILD_DIR}"
else
    echo "No Developer ID found — signing ad-hoc."
    echo "  (macOS will forget this app's permissions on every rebuild.)"
    # No --deep: Apple deprecated it for signing, and there is nothing nested
    # in this bundle to descend into anyway.
    codesign --force --sign - "${BUILD_DIR}"
fi

echo "Built ${BUILD_DIR}"
