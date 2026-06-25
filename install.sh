#!/bin/bash
# Builds Key54 and installs it to /Applications, then launches it.
set -e

cd "$(dirname "$0")"

APP_NAME="Key54"
APP_DIR="/Applications/${APP_NAME}.app"
BUILD_DIR="./build/${APP_NAME}.app"

# Build (ad-hoc signed unless SIGN_IDENTITY is set in the environment).
bash build.sh

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
Go to: System Settings → Privacy & Security → Accessibility → enable Key54.

Once granted, hold the right Command key anywhere to toggle your app.
The app runs silently in the background with no dock icon or menu bar.
It will auto-start at every login.

To uninstall: drag /Applications/${APP_NAME}.app to the Trash.
EOF
