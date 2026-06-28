#!/bin/bash
# Builds, signs, DMG-packages, notarizes, and staples Key54 for distribution.
# Users will see no "unidentified developer" warning.
#
# Prerequisites:
#   1. An active Apple Developer membership.
#   2. A "Developer ID Application" certificate in your login keychain.
#   3. App Store Connect API credentials (see README or Apple docs).
#
# Usage:
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" bash release.sh
#
# Notary credentials (pick one):
#   a) App-specific password  — AC_USERNAME + AC_PASSWORD
#   b) API key (file)         — AC_API_KEY_ID + AC_API_ISSUER_ID + AC_API_KEY_PATH
#   c) API key (keychain)     — AC_API_KEY_ID + AC_API_ISSUER_ID
#                              (key stored as "key54-notary-key" in login keychain)
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Key54"
DMG_NAME="${APP_NAME}.dmg"
DMG_PATH="dist/${DMG_NAME}"

NOTARY_KEY_TMP=""   # cleaned up on exit

cleanup() {
    [ -n "$NOTARY_KEY_TMP" ] && rm -f "$NOTARY_KEY_TMP"
}
trap cleanup EXIT

# ── Sanity checks ──────────────────────────────────────────────────────────

if [ -z "${SIGN_IDENTITY:-}" ]; then
    echo "Usage: SIGN_IDENTITY=\"Developer ID Application: Your Name (TEAMID)\" bash release.sh"
    echo ""
    echo "Available identities on this machine:"
    security find-identity -v -p codesigning | grep "Developer ID Application" || echo "  (none found)"
    exit 1
fi

HAVE_AC_PASS=$([ -n "${AC_USERNAME:-}" ] && [ -n "${AC_PASSWORD:-}" ] && echo 1 || echo 0)
HAVE_AC_API=$([ -n "${AC_API_KEY_ID:-}" ] && [ -n "${AC_API_ISSUER_ID:-}" ] && echo 1 || echo 0)

# If AC_API_KEY_PATH isn't set, try the login keychain.
if [ "$HAVE_AC_API" -eq 1 ] && [ -z "${AC_API_KEY_PATH:-}" ]; then
    KEYCHAIN_KEY=$(security find-generic-password -s "key54-notary-key" -w 2>/dev/null) || true
    if [ -n "$KEYCHAIN_KEY" ]; then
        NOTARY_KEY_TMP=$(mktemp)
        echo "$KEYCHAIN_KEY" > "$NOTARY_KEY_TMP"
        export AC_API_KEY_PATH="$NOTARY_KEY_TMP"
    fi
fi

# Re-check after potential keychain lookup.
HAVE_AC_API=$([ -n "${AC_API_KEY_ID:-}" ] && [ -n "${AC_API_ISSUER_ID:-}" ] && [ -n "${AC_API_KEY_PATH:-}" ] && echo 1 || echo 0)

if [ "$HAVE_AC_PASS" -eq 0 ] && [ "$HAVE_AC_API" -eq 0 ]; then
    echo "Error: no notary credentials found."
    echo ""
    echo "Provide one of:"
    echo "  a) AC_USERNAME (your Apple ID email)  +  AC_PASSWORD (app-specific password)"
    echo "  b) AC_API_KEY_ID  +  AC_API_ISSUER_ID  +  AC_API_KEY_PATH (.p8 file)"
    echo "  c) AC_API_KEY_ID  +  AC_API_ISSUER_ID  (key stored in login keychain)"
    exit 1
fi

# ── Step 1: Build & sign ───────────────────────────────────────────────────

echo "==> Building and signing with '${SIGN_IDENTITY}'..."
SIGN_IDENTITY="${SIGN_IDENTITY}" bash build.sh

# ── Step 2: Package DMG ───────────────────────────────────────────────────

echo "==> Packaging ${DMG_NAME}..."
rm -rf dist
mkdir -p dist/dmgroot
cp -R "build/${APP_NAME}.app" dist/dmgroot/
ln -s /Applications dist/dmgroot/Applications
hdiutil create -volname "${APP_NAME}" -srcfolder dist/dmgroot \
    -ov -format UDZO "${DMG_PATH}"

# ── Step 3: Notarize ──────────────────────────────────────────────────────

echo "==> Submitting ${DMG_NAME} for notarization..."
if [ "$HAVE_AC_API" -eq 1 ]; then
    xcrun notarytool submit "${DMG_PATH}" \
        --key "${AC_API_KEY_PATH}" \
        --key-id "${AC_API_KEY_ID}" \
        --issuer "${AC_API_ISSUER_ID}" \
        --wait
else
    xcrun notarytool submit "${DMG_PATH}" \
        --apple-id "${AC_USERNAME}" \
        --team-id "$(echo "${SIGN_IDENTITY}" | sed -n 's/.*(\(.*\))/\1/p')" \
        --password "${AC_PASSWORD}" \
        --wait
fi

# ── Step 4: Staple ─────────────────────────────────────────────────────────

echo "==> Stapling notarization ticket..."
xcrun stapler staple "${DMG_PATH}"

echo ""
echo "Done! Distribute: ${DMG_PATH}"
