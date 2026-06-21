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
.build/release/ClaudePet --selftest                    # drive real NSEvent click/drag through handlers (CI gate)
.build/release/ClaudePet --make-icon /tmp/icon.png      # render the app icon
.build/release/ClaudePet --aititle /path/to/transcript.jsonl   # debug AI-title parsing

./install.sh                                            # build + wire hooks (dev install)
bash scripts/make-app.sh 1.0.0                          # package dist/ClaudePet.app + installers
./load-pet.sh /path/to/spritesheet.webp                 # swap in a custom sprite
```

There is no unit-test suite. CI (`.github/workflows/build.yml`) is the de-facto test: it
builds release, runs **`--selftest`** (fires real `NSEvent` click/drag through the StackView
handlers and asserts select/reorder behavior), and runs CLI smoke tests asserting per-session
state files are written/removed correctly. Mirror those assertions when changing the
interaction handlers or the `--state` / hook-routing path. CI also requires a clean build with
**no warnings** (see CONTRIBUTING.md).

## Architecture

The binary is **dual-mode**, dispatched by `argv[1]` at the bottom of `main.swift`:

- **CLI mode** (`--state`, `--install-hooks`, `--uninstall-hooks`, `--render`, `--render-stack`,
  `--selftest`, `--make-icon`, `--aititle`): does its work and `exit(0)` — never starts the GUI
  event loop.
- **GUI mode** (no args): acquires a singleton lock, runs the `NSApplication` overlay.

### The data flow (no polling of Claude, no network)

```
Claude Code hook ──▶ ClaudePet --state <s> ──▶ ~/.claude-pet/sessions/<session_id>.json
                                                          │ (folder watched @ 4Hz)
                                            ClaudePet GUI ◀┘  reconciles the stack, animates
```

Hooks invoke `--state <state>`. Each invocation reads the hook's JSON from **stdin**
(`readHookInput`) to get `session_id`/`cwd`/`transcript_path`, writes one state file per
session under `~/.claude-pet/sessions/`, then `ensureRunning()` auto-launches the GUI if it
isn't alive. State `off` deletes the session file (pet disappears).

The GUI is a **single stacked overlay** (one `NSWindow` whose contentView is `StackView`),
not one window per session. `AppDelegate.sync()` (timer @ 0.25s) reads all session files and
prunes stale ones (>12h, `SESSION_STALE_SECONDS`). The session list keeps a **stable order**
(`order: [String]`): existing positions are preserved, new sessions append (oldest-first),
ended ones drop out — it never reorders on state change. The user-**selected** session
(`selectedID`) shows as the big animated `PetView` in the corner; all sessions render as a
list above it inside `StackView`, with the selected row highlighted. Interactions on
`StackView`: **click a row** → `onSelect` (just changes selection), **scroll** → `onCycle`
(steps selection), **drag a row** → `onReorder` (the row lifts and follows the cursor; mutates
`order`), **drag the pet/empty area** → moves the window. The window is bottom-anchored so the
pet stays put. A single session hides the list and just shows the pet with its name.

The user's manual arrangement (`order` + `selectedID`) is persisted to
`~/.claude-pet/layout.json` and restored on launch (stale ids pruned in `sync()`), so it
survives overlay restarts.

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

Session labels prefer Claude Code's AI-generated session title, parsed by `readAITitle()`
from the tail of the transcript JSONL (records with `"type":"ai-title"`, latest wins), and
fall back to the project folder name (`label()`). The selected pet's caption (shown for single
*and* multi) wraps to two lines via `PetView.wrapCaption`; list rows single-line truncate.

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

- Branches: `main` is stable/released; `dev` mirrors it. **External contributors open PRs
  against `dev`** (per CONTRIBUTING.md). For solo/direct work we commit to `main` and
  fast-forward `dev` to match (see procedure below).
- **Commit messages: clean and professional, NO AI attribution** — never mention Claude /
  Anthropic / "Generated with…" / "Co-Authored-By: Claude". (Global user rule.)
- License is PolyForm Noncommercial — keep any bundled/added art noncommercial-clean (the
  mascot/icon are drawn in code on purpose; never commit third-party sprites).

## Release & maintenance procedures

We ship a single distributable: a prebuilt **`ClaudePet.app`** plus double-click
`Install/Uninstall .command` scripts, zipped as `ClaudePet-macos.zip` and attached to a
GitHub Release. Versioning is **semver** via `vX.Y.Z` git tags (patch = fix/docs-with-build,
minor = user-facing feature, major = breaking). The version passed to `make-app.sh` becomes
the bundle's `CFBundleShortVersionString`.

### Cut a release (the standard flow)

1. **Make the change.** Build must be warning-free; run the gates locally:
   ```bash
   swift build -c release 2>&1 | grep -i warning   # must be empty
   .build/release/ClaudePet --selftest             # interaction gate (exit 0)
   ```
2. **Keep docs in sync in the SAME change** (see "Docs to update" below). Regenerate any
   affected screenshots with `--render <state> docs/pet_<state>.png`, `--render-stack
   docs/stack.png`, and the icon with `make-icon.sh`.
3. **Package the app:** `bash scripts/make-app.sh X.Y.Z` → `dist/ClaudePet.app` + installers.
4. **(Optional) dogfood locally** — reinstall the running copy without it hanging:
   ```bash
   pkill -x ClaudePet; sleep 1; pkill -9 -x ClaudePet
   rm -f ~/.claude-pet/pet.lock ~/.claude-pet/pet.pid
   rm -rf /Applications/ClaudePet.app && cp -R dist/ClaudePet.app /Applications/ClaudePet.app
   /Applications/ClaudePet.app/Contents/MacOS/ClaudePet --install-hooks < /dev/null
   ```
5. **Commit + push `main`, fast-forward `dev`** (clean message, no AI attribution):
   ```bash
   git add -A && git commit -m "..."
   git push origin main
   git branch -f dev main && git push origin dev
   ```
6. **Tag → triggers the release build:**
   ```bash
   git tag vX.Y.Z && git push origin vX.Y.Z
   ```
   CI builds, runs `--selftest` + smoke, packages the zip, and publishes the GitHub Release
   (the workflow has `permissions: contents: write`; without it the release step 403s).
7. **Verify:** `gh run list --branch vX.Y.Z` shows success, and
   `gh release view vX.Y.Z` lists `ClaudePet-macos.zip`.

**Docs-only change** (e.g. a screenshot): commit + push `main`, fast-forward `dev`, **no tag**
(no need to cut a release).

### Keeping README & CLAUDE.md current (do this as things change)

Treat docs as part of the change, not a follow-up. When you touch:
- **`HOOK_WIRING`** → update the README hook table.
- **states / animations / gestures / multi-session layout** → update the README
  "Session state → animation", "Calm by design", and "Multiple sessions" sections, and the
  Architecture section here. Refresh screenshots.
- **CLI flags** → update the Commands block here and any README install/usage steps.
- **the install/hook/process behavior** → update Architecture + "Three things that must stay
  in sync" + "Why the stdin/process handling looks defensive".
- Re-read the **"Three things that must stay in sync"** list before editing `describe()`,
  `CODEX_ROW_SPECS`, or `HOOK_WIRING` — these have cross-file coupling.

Keep this file matched to the code (file names, function names, flags, behavior). If a section
here no longer matches `main.swift`, fix it in the same commit. The README is the user-facing
story; CLAUDE.md is the contributor/agent map — don't let either drift.

### Non-technical install (what the release zip delivers)

`Install Claude Pet.command` stops any running copy (kill + wait), copies the app to
`/Applications`, clears the Gatekeeper quarantine flag, and runs `--install-hooks` (append-only
into `~/.claude/settings.json`). The app is **unsigned**, so first launch may need
right-click → Open. (Future improvement: codesign/notarize to remove that step.)
