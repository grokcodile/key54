#!/bin/bash
# Captures screenshots/settings.png — a transparent shot of just the settings
# window (no drop shadow, no background). Run by hand, or via install.sh (which
# calls it after installing). Not part of the CI release build.
#
#   bash screenshot.sh
#
# Uses the already-built/installed app (prefers /Applications, falls back to
# ./build). Needs Screen Recording permission, granted once. Optional: install
# pngquant to shrink the PNG.
set -e

cd "$(dirname "$0")"
APP_NAME="Key54"
OUT="$(pwd)/screenshots/settings.png"

APP="/Applications/${APP_NAME}.app"
[ -d "$APP" ] || APP="./build/${APP_NAME}.app"
[ -d "$APP" ] || { echo "No ${APP_NAME}.app found — run 'bash install.sh' first."; exit 1; }

"${APP}/Contents/MacOS/${APP_NAME}" --screenshot "$OUT"

if command -v pngquant >/dev/null 2>&1; then
    pngquant --quality=70-95 --speed 1 --ext .png --force "$OUT" || true
fi

# Tie the README image cache-buster to the release version so GitHub re-fetches
# the screenshot whenever the version bumps (see Info.plist).
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist 2>/dev/null || true)
if [ -n "$VERSION" ]; then
    sed -i '' -E "s/(settings\.png\?v=)[0-9.]+/\1${VERSION}/" README.md
fi

# Mirror the shot into the GitHub Pages site so the landing page stays current.
[ -d docs ] && cp "$OUT" docs/settings.png
