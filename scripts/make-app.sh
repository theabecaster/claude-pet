#!/usr/bin/env bash
# Builds ClaudePet.app and stages the double-click installers in dist/.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$DIR"

VERSION="${1:-1.0.0}"
case "$VERSION" in (*[!0-9.]*) VERSION="1.0.0" ;; esac   # fall back if not semver

echo "==> swift build -c release"
swift build -c release

APP="dist/ClaudePet.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/ClaudePet "$APP/Contents/MacOS/ClaudePet"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Claude Pet</string>
  <key>CFBundleDisplayName</key><string>Claude Pet</string>
  <key>CFBundleIdentifier</key><string>com.claudepet.overlay</string>
  <key>CFBundleExecutable</key><string>ClaudePet</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

cp "scripts/Install Claude Pet.command" dist/
cp "scripts/Uninstall Claude Pet.command" dist/
chmod +x dist/*.command

echo "==> Built $APP (v$VERSION)"
