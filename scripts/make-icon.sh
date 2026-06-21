#!/usr/bin/env bash
# Renders the app icon and builds Resources/AppIcon.icns (committed to the repo).
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$DIR"

swift build -c release >/dev/null
mkdir -p Resources
SRC="$(mktemp -d)/AppIcon.png"
.build/release/ClaudePet --make-icon "$SRC"

ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for sz in 16 32 128 256 512; do
  sips -z $sz $sz "$SRC" --out "$ICONSET/icon_${sz}x${sz}.png" >/dev/null
  sips -z $((sz*2)) $((sz*2)) "$SRC" --out "$ICONSET/icon_${sz}x${sz}@2x.png" >/dev/null
done
sips -z 1024 1024 "$SRC" --out "$ICONSET/icon_512x512@2x.png" >/dev/null

iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
cp "$SRC" docs/icon.png
echo "==> Resources/AppIcon.icns + docs/icon.png built"
