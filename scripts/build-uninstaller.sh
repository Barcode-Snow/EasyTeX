#!/bin/bash
# Builds "build/Uninstall EasyTeX.app" from scripts/Uninstaller.applescript.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Uninstall EasyTeX.app"
echo "▸ Building $APP"
rm -rf "$APP"
mkdir -p build
osacompile -o "$APP" scripts/Uninstaller.applescript

PLIST="$APP/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string "app.easytex.uninstaller" "$PLIST"
plutil -replace CFBundleName -string "Uninstall EasyTeX" "$PLIST"
plutil -replace NSAppleEventsUsageDescription -string "The uninstaller asks EasyTeX to quit and, if needed, asks Finder to move items to the Trash." "$PLIST"
scripts/make-icon.sh
cp build/AppIcon.icns "$APP/Contents/Resources/applet.icns"

codesign --force --deep --sign "${SIGN_IDENTITY:--}" "$APP"
echo "✓ Built $APP"
