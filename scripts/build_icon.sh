#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
SOURCE="website_content/apps/aethertransfer/media/icon.png"
TARGET="outputs/AetherTransfer.app/Contents/Resources/AppIcon.icns"
if [[ -f "$TARGET" && "$TARGET" -nt "$SOURCE" ]]; then exit 0; fi
ICONSET=".build/AppIcon.iconset"
mkdir -p "$ICONSET" "$(dirname "$TARGET")"
for SIZE in 16 32 128 256 512; do
    sips -z "$SIZE" "$SIZE" "$SOURCE" --out "$ICONSET/icon_${SIZE}x${SIZE}.png" >/dev/null
    DOUBLE=$((SIZE * 2))
    sips -z "$DOUBLE" "$DOUBLE" "$SOURCE" --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$TARGET"
