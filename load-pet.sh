#!/usr/bin/env bash
# Select which sprite sheet the overlay uses.
#   ./load-pet.sh                 list available sprites
#   ./load-pet.sh <name>          activate ~/.claude-pet/pets/<name>.png
#   ./load-pet.sh /path/to.png    import + activate an external sheet
set -euo pipefail

STATE_DIR="$HOME/.claude-pet"
PETS="$STATE_DIR/pets"
ACTIVE="$STATE_DIR/active.png"
mkdir -p "$PETS"

if [ $# -eq 0 ]; then
  echo "Available sprites in $PETS:"
  ls -1 "$PETS"/*.png 2>/dev/null | xargs -n1 basename 2>/dev/null || echo "  (none — drop a .png sheet in $PETS)"
  echo
  echo "Active: $( [ -e "$ACTIVE" ] && readlink "$ACTIVE" 2>/dev/null || echo "built-in placeholder" )"
  exit 0
fi

arg="$1"
if [ -f "$arg" ]; then
  cp "$arg" "$PETS/$(basename "$arg")"
  src="$PETS/$(basename "$arg")"
else
  src="$PETS/${arg%.png}.png"
fi

[ -f "$src" ] || { echo "No such sprite: $src"; exit 1; }
ln -sf "$src" "$ACTIVE"
echo "Activated $(basename "$src"). Restart the pet to apply:"
echo "  pkill -f ClaudePet ; (the next Claude Code hook relaunches it)"
