#!/bin/bash
# Double-click to install Claude Pet. No terminal knowledge needed.
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"

echo "Installing Claude Pet…"

# Fully stop any running copy before replacing it, so the copy can't hang on a
# busy binary. Wait for it to actually exit.
pkill -x ClaudePet 2>/dev/null || true
for _ in 1 2 3 4 5 6 7 8 9 10; do
  pgrep -x ClaudePet >/dev/null 2>&1 || break
  sleep 0.3
done
pkill -9 -x ClaudePet 2>/dev/null || true
rm -f "$HOME/.claude-pet/pet.lock" "$HOME/.claude-pet/pet.pid" 2>/dev/null || true

rm -rf "/Applications/ClaudePet.app"
cp -R "$DIR/ClaudePet.app" "/Applications/ClaudePet.app"

# Clear the quarantine flag so the unsigned app opens without a Gatekeeper block.
xattr -dr com.apple.quarantine "/Applications/ClaudePet.app" 2>/dev/null || true

# Wire Claude Code hooks (non-destructive — existing hooks are preserved).
"/Applications/ClaudePet.app/Contents/MacOS/ClaudePet" --install-hooks < /dev/null

open "/Applications/ClaudePet.app"

echo ""
echo "🐾 Done! A little Claude pet now lives in the corner of your screen."
echo "  It reacts to Claude Code in real time."
echo "  Use the 🐾 icon in your menu bar to show/hide it or load a custom sprite."
echo ""
read -n 1 -s -r -p "Press any key to close this window."
