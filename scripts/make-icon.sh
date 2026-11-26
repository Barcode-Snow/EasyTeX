#!/bin/bash
# Turns Resources/AppIcon.png into build/AppIcon.icns (used by the app and the uninstaller).
set -euo pipefail
cd "$(dirname "$0")/.."

ICNS="build/AppIcon.icns"
[ "$ICNS" -nt Resources/AppIcon.png ] && exit 0

ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET" build
for s in 16 32 128 256 512; do
  sips -z $s $s Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$ICNS"
rm -rf "$(dirname "$ICONSET")"
