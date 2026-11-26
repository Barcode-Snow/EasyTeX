#!/bin/bash
# Packs a built app, an Applications shortcut and the uninstaller into a disk image.
#   scripts/make-dmg.sh        -> build/EasyTeX.dmg
#   scripts/make-dmg.sh PLUS   -> build/EasyTeX-PLUS.dmg
set -euo pipefail
cd "$(dirname "$0")/.."

if [ "${1:-}" = "PLUS" ]; then NAME="EasyTeX PLUS"; OUT="build/EasyTeX-PLUS.dmg"; FORMAT="ULMO"
else NAME="EasyTeX"; OUT="build/EasyTeX.dmg"; FORMAT="UDZO"; fi
[ -d "build/$NAME.app" ] || { echo "Run scripts/build-app.sh ${1:-} first"; exit 1; }
scripts/build-uninstaller.sh

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "build/$NAME.app" "build/Uninstall EasyTeX.app" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

echo "▸ Creating $OUT"
rm -f "$OUT"
hdiutil create -volname "$NAME" -srcfolder "$STAGE" -format "$FORMAT" "$OUT" >/dev/null
echo "✓ $OUT ($(du -h "$OUT" | cut -f1))"
