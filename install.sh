#!/bin/bash
set -e

cd "$(dirname "$0")"

APP_NAME="Trapdoor"
APP_DIR="/Applications/${APP_NAME}.app"
BUILD_DIR="./build/${APP_NAME}.app"

echo "Building ${APP_NAME}..."

rm -rf ./build
mkdir -p "${BUILD_DIR}/Contents/MacOS"
mkdir -p "${BUILD_DIR}/Contents/Resources"

# Icon — regenerate from source PNG (Core Graphics resize, preserves alpha)
SRC_ICON="trapdoor art 2.png"
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

swiftc -O main.swift \
    -framework Cocoa \
    -framework ServiceManagement \
    -o "${BUILD_DIR}/Contents/MacOS/${APP_NAME}"

cp Info.plist "${BUILD_DIR}/Contents/Info.plist"

codesign --force --deep --sign - "${BUILD_DIR}"

echo "Installing to ${APP_DIR}..."
killall "${APP_NAME}" 2>/dev/null || true
rm -rf "${APP_DIR}"

if ! cp -R "${BUILD_DIR}" "${APP_DIR}" 2>/dev/null; then
    echo "Need admin password to copy into /Applications:"
    sudo cp -R "${BUILD_DIR}" "${APP_DIR}"
fi

echo "Launching ${APP_NAME}..."
sleep 1
open "${APP_DIR}"

cat <<EOF

Done. On first run, macOS will prompt for Accessibility permission.
Go to: System Settings → Privacy & Security → Accessibility → enable Trapdoor.

Once granted, hold the right Command key anywhere to toggle your app.
The app runs silently in the background with no dock icon or menu bar.
It will auto-start at every login.

To uninstall: drag /Applications/${APP_NAME}.app to the Trash.
EOF
