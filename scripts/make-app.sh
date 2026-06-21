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

# App icon (generate if missing).
[ -f Resources/AppIcon.icns ] || bash scripts/make-icon.sh
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Claude Pet</string>
  <key>CFBundleDisplayName</key><string>Claude Pet</string>
  <key>CFBundleIdentifier</key><string>com.claudepet.overlay</string>
  <key>CFBundleExecutable</key><string>ClaudePet</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIconName</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Code-sign the bundle. The Swift linker leaves only a partial signature on the
# inner executable (it claims sealed resources exist, but never writes a
# CodeResources seal), so `codesign --verify` fails. A quarantined app in that
# inconsistent state is what modern macOS reports as "damaged — move to Trash"
# (and right-click → Open can't recover it). A proper re-sign writes a consistent
# seal.
#
# If $CODESIGN_IDENTITY is set (CI on a tagged release, with a Developer ID cert
# imported), sign with it + hardened runtime + a secure timestamp — the prereqs
# for notarization, which removes the Gatekeeper prompt entirely. Otherwise sign
# ad-hoc, which still downgrades the fatal "damaged" verdict to the recoverable
# "unidentified developer → Open Anyway"; the installer then strips quarantine.
if command -v codesign >/dev/null 2>&1; then
  if [ -n "${CODESIGN_IDENTITY:-}" ]; then
    echo "==> Code-signing with Developer ID ($CODESIGN_IDENTITY)"
    SIGN_ARGS=(--force --options runtime --timestamp --sign "$CODESIGN_IDENTITY")
  else
    echo "==> Ad-hoc code-signing (no Developer ID — not notarizable)"
    SIGN_ARGS=(--force --timestamp=none --sign -)
  fi
  codesign "${SIGN_ARGS[@]}" "$APP/Contents/MacOS/ClaudePet"
  codesign "${SIGN_ARGS[@]}" "$APP"
  codesign --verify --strict "$APP"   # hard gate: fails the build if the seal is inconsistent
  echo "    signature verified"
else
  echo "!! codesign not found — bundle will be unsigned (Gatekeeper will mark it damaged)" >&2
fi

cp "scripts/Install Claude Pet.command" dist/
cp "scripts/Uninstall Claude Pet.command" dist/
chmod +x dist/*.command

echo "==> Built $APP (v$VERSION)"
