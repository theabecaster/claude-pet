#!/usr/bin/env bash
# Load a pet sprite into Claude Pet. Codex-compatible: accepts any
# codex-pets.net / hatch-pet spritesheet (8x9 atlas, 192x208 cells, WebP).
#
#   ./load-pet.sh /path/to/spritesheet.webp     activate a sheet
#   ./load-pet.sh /path/to/petfolder            folder containing spritesheet.webp
#   ./load-pet.sh https://…/spritesheet.webp    download + activate
#   ./load-pet.sh                                show what's active
set -euo pipefail

STATE_DIR="$HOME/.claude-pet"
mkdir -p "$STATE_DIR/pets"

if [ $# -eq 0 ]; then
  echo "Active sprite:"
  ls -1 "$STATE_DIR"/active.* 2>/dev/null || echo "  (built-in default pet)"
  exit 0
fi

arg="$1"
tmp=""

# Remote URL -> download first
if [[ "$arg" =~ ^https?:// ]]; then
  tmp="$(mktemp -d)/$(basename "${arg%%\?*}")"
  echo "Downloading $arg…"
  curl -fsSL "$arg" -o "$tmp"
  arg="$tmp"
fi

# Folder -> find the spritesheet inside
if [ -d "$arg" ]; then
  for f in spritesheet.webp spritesheet.png; do
    [ -f "$arg/$f" ] && arg="$arg/$f" && break
  done
fi

[ -f "$arg" ] || { echo "No sprite found at: $1"; exit 1; }

ext="webp"; [[ "${arg##*.}" == "png" ]] && ext="png"
rm -f "$STATE_DIR"/active.webp "$STATE_DIR"/active.png
cp "$arg" "$STATE_DIR/active.$ext"
echo "Activated $(basename "$arg") → active.$ext"
echo "Restart the pet to apply:  pkill -f ClaudePet   (a hook relaunches it)"
