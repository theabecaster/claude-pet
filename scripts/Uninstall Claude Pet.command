#!/bin/bash
# Double-click to completely remove Claude Pet.
echo "Removing Claude Pet…"
"/Applications/ClaudePet.app/Contents/MacOS/ClaudePet" --uninstall-hooks 2>/dev/null || true
pkill -f ClaudePet 2>/dev/null || true
rm -rf "/Applications/ClaudePet.app"
rm -rf "$HOME/.claude-pet"
echo "🐾 Claude Pet has been removed. Your Claude Code hooks were left intact."
echo ""
read -n 1 -s -r -p "Press any key to close this window."
