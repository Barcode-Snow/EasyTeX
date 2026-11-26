#!/bin/bash
# Builds the app for Apple Silicon.
#   scripts/build-app.sh        -> build/EasyTeX.app       (uses or installs TeX on first launch)
#   scripts/build-app.sh PLUS   -> build/EasyTeX PLUS.app  (TeX Live inside; installs it into build/texlive first)
set -euo pipefail
cd "$(dirname "$0")/.."

if [ "${1:-}" = "PLUS" ]; then NAME="EasyTeX PLUS"; ID="app.easytex.PLUS"
else NAME="EasyTeX"; ID="app.easytex.lite"; fi
APP="build/$NAME.app"

echo "▸ Compiling"
swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)/EasyTeX"

echo "▸ Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/EasyTeX"
strip -Sx "$APP/Contents/MacOS/EasyTeX"   # drop debug symbols (they contain the build machine's paths)
cp -R Resources/editor "$APP/Contents/Resources/editor"
sed -e "s/__NAME__/$NAME/g" -e "s/__BUNDLE_ID__/$ID/g" Resources/Info.plist > "$APP/Contents/Info.plist"
scripts/make-icon.sh
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

if [ "${1:-}" = "PLUS" ]; then
  scripts/install-texlive.sh build/texlive
  echo "▸ Copying TeX Live into the app"
  cp -R build/texlive "$APP/Contents/Resources/texlive"
fi

echo "▸ Signing (ad-hoc unless SIGN_IDENTITY is set)"
if [ -n "${SIGN_IDENTITY:-}" ]; then
  codesign --force --deep --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
else
  codesign --force --deep --sign - "$APP"
fi

echo "✓ Built $APP"
