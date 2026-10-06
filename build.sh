#!/bin/bash
# Builds Key54.app into ./build. Used by both install.sh and CI.
#
# Code-signing: SIGN_IDENTITY picks the identity and must be a certificate's SHA-1
# hash (40 hex digits). It defaults to the Developer ID Application cert for team
# 8UP5SFXY56 (G2 Sub-CA, expires 2031-09-16). Sign by hash, never by name: the
# keychain can hold several identities with the identical name — the older cert
# Apple is retiring is still there — so a name is ambiguous (codesign refuses to
# choose, and the old `grep | head -1` quietly took the first, older one). An
# identity you set explicitly that isn't usable is an error, even if it's the same
# hash as the default; only the *default* missing (a machine that never had this
# cert) falls back to ad-hoc.
#
# The fallback matters for more than distribution. macOS keys the Accessibility
# grant to the app's designated requirement — with a Developer ID that's the
# stable "identifier + team OU", but an ad-hoc signature has no cert, so
# it reduces to the binary's cdhash. That changes on *every* build, so each
# reinstall looks like a brand-new app and has to be re-granted Accessibility.
set -e

cd "$(dirname "$0")"

APP_NAME="Key54"
BUILD_DIR="./build/${APP_NAME}.app"
# Mirrored by the pinned hash in .github/workflows/release.yml.
DEFAULT_SIGN_IDENTITY="DEA1A3749B06CF3619F72152EFC35A48E380C4E4"
# Remember whether the caller chose the identity (empty counts as unset): one that
# was chosen and can't be used must fail rather than fall back to ad-hoc — CI
# exports exactly the default hash, so comparing against the default can't tell.
SIGN_IDENTITY_EXPLICIT="${SIGN_IDENTITY:+1}"
SIGN_IDENTITY="${SIGN_IDENTITY:-$DEFAULT_SIGN_IDENTITY}"
if ! printf '%s' "$SIGN_IDENTITY" | grep -Eq '^[0-9A-Fa-f]{40}$'; then
    echo "error: SIGN_IDENTITY must be a certificate SHA-1 hash (40 hex digits), not a name." >&2
    exit 1
fi
# `find-identity -v` lists only *valid* identities, so a cert that is expired,
# untrusted or missing its private key is absent here too — "not found" below
# means "not usable", not necessarily "not installed".
if ! security find-identity -v -p codesigning 2>/dev/null | grep -qiE "^ *[0-9]+\) ${SIGN_IDENTITY} "; then
    if [ -n "$SIGN_IDENTITY_EXPLICIT" ]; then
        echo "error: SIGN_IDENTITY=${SIGN_IDENTITY} is not among the valid code-signing identities" >&2
        echo "       (missing, expired, untrusted, or no private key)." >&2
        exit 1
    fi
    SIGN_IDENTITY=""
fi
BUILD_ABS="$PWD/${BUILD_DIR#./}"

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

# Info.plist's LSMinimumSystemVersion is the one place the supported macOS is set:
# the deployment target is read from it here, and release.yml writes the same
# value into the Homebrew cask's `depends_on macos`. Releases are Apple Silicon
# only, so the architecture is pinned rather than taken from whatever Mac builds.
MIN_MACOS="$(plutil -extract LSMinimumSystemVersion raw Info.plist)"
# -Osize rather than -O, as in Pullcord: this app sits idle on a flagsChanged
# event tap, and the one thing that isn't idle — the HUD — animates on the render
# server via CALayer rather than here. Size is worth more than the last few
# percent of throughput. -Osize barely moves the binary on its own (315KB → 313KB)
# but it emits fewer specializations, so it strips 16KB smaller than -O does.
swiftc -Osize main.swift \
    -target "arm64-apple-macos${MIN_MACOS}" \
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
    # Prove who signed it. `codesign -dvv` can't: the old and new certs share a
    # name and team and it prints no hash, so a signature from the wrong one reads
    # identically. The signing certificate's own fingerprint is unambiguous.
    CERT_DIR="$(mktemp -d)"
    ( cd "$CERT_DIR" && codesign -d --extract-certificates "$BUILD_ABS" 2>/dev/null )
    SIGNED_BY="$(openssl x509 -inform DER -in "$CERT_DIR/codesign0" -noout -fingerprint -sha1 | sed 's/.*=//; s/://g')"
    rm -rf "${CERT_DIR:?}"
    if [ "$(printf '%s' "$SIGNED_BY" | tr a-f A-F)" != "$(printf '%s' "$SIGN_IDENTITY" | tr a-f A-F)" ]; then
        echo "error: signed by certificate ${SIGNED_BY}, expected ${SIGN_IDENTITY}." >&2
        exit 1
    fi
    echo "Signed by certificate ${SIGNED_BY}"
else
    echo "Signing identity ${DEFAULT_SIGN_IDENTITY} not among the valid identities — signing ad-hoc."
    echo "  (macOS will forget this app's permissions on every rebuild.)"
    # No --deep: Apple deprecated it for signing, and there is nothing nested
    # in this bundle to descend into anyway.
    codesign --force --sign - "${BUILD_DIR}"
fi

echo "Built ${BUILD_DIR}"
