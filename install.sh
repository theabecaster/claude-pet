#!/usr/bin/env bash
# Source install (for developers / people with Xcode CLT).
# Non-technical users: download the prebuilt app from GitHub Releases and run
# "Install Claude Pet.command" instead — no compiler needed.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

command -v swift >/dev/null 2>&1 || {
  echo "Swift toolchain not found. Install Xcode Command Line Tools: xcode-select --install"
  exit 1
}

echo "==> Building ClaudePet (release)…"
swift build -c release

mkdir -p "$HOME/.claude-pet/pets"
printf '{"state":"idle"}\n' > "$HOME/.claude-pet/state.json"

echo "==> Wiring Claude Code hooks (non-destructive, idempotent)…"
.build/release/ClaudePet --install-hooks

echo
echo "Done. The pet auto-launches on the next Claude Code hook, or run it now:"
echo "  .build/release/ClaudePet &"
echo
echo "Custom sprites:  ./load-pet.sh /path/to/sheet.png   (or use the ✳ menu-bar icon)"
echo "Uninstall hooks: .build/release/ClaudePet --uninstall-hooks"
