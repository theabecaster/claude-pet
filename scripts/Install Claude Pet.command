#!/bin/bash
# Double-click to install Claude Pet. No terminal knowledge needed.
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"

echo "Installing Claude Pet…"
pkill -f ClaudePet 2>/dev/null || true
rm -rf "/Applications/ClaudePet.app"
cp -R "$DIR/ClaudePet.app" "/Applications/ClaudePet.app"

# Clear the quarantine flag so the unsigned app opens without a Gatekeeper block.
xattr -dr com.apple.quarantine "/Applications/ClaudePet.app" 2>/dev/null || true

# Wire Claude Code hooks (non-destructive — existing hooks are preserved).
"/Applications/ClaudePet.app/Contents/MacOS/ClaudePet" --install-hooks

open "/Applications/ClaudePet.app"

echo ""
echo "🐾 Done! A little Claude pet now lives in the corner of your screen."
echo "  It reacts to Claude Code in real time."
echo "  Use the 🐾 icon in your menu bar to show/hide it or load a custom sprite."
echo ""
read -n 1 -s -r -p "Press any key to close this window."
