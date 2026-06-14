#!/bin/bash
# Captures screenshots/settings.png — a transparent shot of just the settings
# window (no drop shadow, no background). Run by hand; intentionally NOT wired
# into build.sh or install.sh.
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
