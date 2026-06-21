# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Claude Pet is a single Swift/AppKit macOS binary that renders a floating desktop pet
which mirrors Claude Code session state in real time. It's Codex-pet-sprite compatible.
There is essentially one source file: `Sources/ClaudePet/main.swift` (~700 lines). No
runtime dependencies; macOS 12+ (WebP decoding is built in via `NSImage`).

## Commands

```bash
swift build -c release                                  # build (the only build step)
.build/release/ClaudePet &                              # run the overlay GUI
.build/release/ClaudePet --state waiting                # simulate a hook firing
.build/release/ClaudePet --render running /tmp/p.png    # offscreen PNG preview of a state
.build/release/ClaudePet --render-stack /tmp/s.png      # offscreen preview of the multi-session stack
.build/release/ClaudePet --make-icon /tmp/icon.png      # render the app icon
.build/release/ClaudePet --aititle /path/to/transcript.jsonl   # debug AI-title parsing

./install.sh                                            # build + wire hooks (dev install)
bash scripts/make-app.sh 1.0.0                          # package dist/ClaudePet.app + installers
./load-pet.sh /path/to/spritesheet.webp                 # swap in a custom sprite
```

There is no test suite. CI (`.github/workflows/build.yml`) is the de-facto test: it builds
release and runs CLI smoke tests asserting per-session state files are written/removed
correctly. Mirror those assertions when changing the `--state` / hook-routing path. CI also
requires a clean build with **no warnings** (see CONTRIBUTING.md).

## Architecture

The binary is **dual-mode**, dispatched by `argv[1]` at the bottom of `main.swift`:

- **CLI mode** (`--state`, `--install-hooks`, `--uninstall-hooks`, `--render`, `--make-icon`,
  `--aititle`): does its work and `exit(0)` — never starts the GUI event loop.
- **GUI mode** (no args): acquires a singleton lock, runs the `NSApplication` overlay.

### The data flow (no polling of Claude, no network)

```
Claude Code hook ──▶ ClaudePet --state <s> ──▶ ~/.claude-pet/sessions/<session_id>.json
                                                          │ (folder watched @ 4Hz)
                                            ClaudePet GUI ◀┘  reconciles windows, animates
```

Hooks invoke `--state <state>`. Each invocation reads the hook's JSON from **stdin**
(`readHookInput`) to get `session_id`/`cwd`/`transcript_path`, writes one state file per
session under `~/.claude-pet/sessions/`, then `ensureRunning()` auto-launches the GUI if it
isn't alive. State `off` deletes the session file (pet disappears).

The GUI is a **single stacked overlay** (one `NSWindow` whose contentView is `StackView`),
not one window per session. `AppDelegate.sync()` (timer @ 0.25s) reads all session files,
prunes stale ones (>12h, `SESSION_STALE_SECONDS`), and sorts them by `priority(state)` —
needs-input > error > ready > working > idle (`naturalOrder`). The most-relevant session is
the **primary** (a prominent animated `PetView` anchored in the corner); the rest render as a
clickable list above it inside `StackView`. The window is bottom-anchored so the pet never
jumps as sessions come and go. Users go through the stack via `StackView`: **scroll** to cycle
(`onCycle`→`cycle()`), **click a row** to feature a session, **click the pet** to release the
pin (`onPin`); `pinnedID` overrides auto-promotion and shows a "pinned" label.

Animation is **continuous (30fps, `PetView.advance()` driven by a `ticks`/`phase` clock)**,
not discrete frame stepping. Motion is keyed to an *attention budget* (`PetView.motion()`):
working/idle barely move; `waiting` bobs with a pulsing red halo; `failed` shakes; `review`
gives a soft positive bob. Sprite sheets advance frames at a per-state fps (calm states
slower); `drawBuddy()` uses `phase` for smooth default-mascot motion.

### Three things that must stay in sync

1. **`HOOK_WIRING`** — maps Claude Code hook events → Codex states. `installHooks()` writes
   these into `~/.claude/settings.json` **append-only and idempotently** (it strips any prior
   `--state` entry before re-adding, so reinstall never duplicates and never clobbers the
   user's other hooks). If you add/rename a hook event, update this table and the README's
   hook table.
2. **`CODEX_ROW_SPECS`** — the Codex atlas contract: an 8-column × 9-row sheet of 192×208
   cells, each row a named state with a frame count. This is fixed by codex-pets.net /
   `hatch-pet` compatibility — **do not change it** unless intentionally breaking that
   compatibility. `codexAnimations()` derives frame-index lists from it.
3. **`describe(_:)`** — maps a state string → animation row + status pill label + dot color +
   optional one-shot fallback. `waving`→`idle` and `jumping`→`review` are one-shots: they play
   once then settle (handled in `PetView.advance()`).

### Rendering

`PetView.draw` blits one cell from the active sprite sheet (`~/.claude-pet/active.webp|png`).
If no custom sprite is loaded, it falls back to `drawBuddy()` — the **original mascot drawn
entirely in code** (no third-party art; also used for the app icon). Sheet layout/fps/scale
come from `Frames` (defaults overridable via `~/.claude-pet/frames.json`; see
`frames.json.example`). The status pill and session caption stack upward above the pet.

Session captions prefer Claude Code's AI-generated session title, parsed by `readAITitle()`
from the tail of the transcript JSONL (records with `"type":"ai-title"`, latest wins), and
fall back to the project folder name when multiple sessions are active.

### Why the stdin/process handling looks defensive

Hooks run synchronously inside Claude Code, so any blocking would hang the user's session.
Two deliberate guards (do not "simplify" them away):
- `readHookInput()` reads stdin via `poll()` with a hard time cap so a hook can never block on
  a kept-open pipe.
- `ensureRunning()` spawns the GUI with all stdio set to `nullDevice` so the short-lived hook
  process doesn't inherit (and wait on) the long-lived GUI.
- `acquireSingletonOrExit()` uses an exclusive `flock` so racing `--state` calls that each try
  to spawn a GUI resolve to exactly one surviving overlay.

## Conventions

- Branches: `main` is stable/released; **open PRs against `dev`** (per CONTRIBUTING.md).
- Releasing: tag `vX.Y.Z` on `main` → CI builds, packages `ClaudePet-macos.zip`, and attaches
  it to a GitHub Release.
- License is PolyForm Noncommercial — keep any bundled/added art noncommercial-clean.
