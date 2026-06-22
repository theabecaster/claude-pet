# CLAUDE.md

Guidance for working in this repo.

## What this is

Claude Pet is a single Swift/AppKit macOS binary that renders a floating desktop pet
mirroring Claude Code session state in real time. Codex-pet-sprite compatible. One
source file: `Sources/ClaudePet/main.swift`. No runtime deps; macOS 12+ (WebP via `NSImage`).

## Commands

```bash
swift build -c release                                  # build (the only build step)
.build/release/ClaudePet &                              # run the overlay GUI
.build/release/ClaudePet --state waiting                # simulate a hook firing
.build/release/ClaudePet --render running /tmp/p.png    # offscreen PNG preview of a state
.build/release/ClaudePet --render-stack /tmp/s.png      # preview the multi-session stack
.build/release/ClaudePet --render-menubar /tmp/m.png    # preview the menu-bar icon
.build/release/ClaudePet --status                       # terminal health + session report
.build/release/ClaudePet --selftest                     # NSEvent interaction + logic checks (CI gate)
.build/release/ClaudePet --meta <transcript.jsonl>      # debug transcript meta
./install.sh                                            # build + wire hooks (dev install)
bash scripts/make-app.sh 1.0.0                          # package dist/ClaudePet.app
bash scripts/next-version.sh                            # preview next auto-release version
```

CI (`.github/workflows/build.yml`) is the test: clean build **with no warnings**, `--selftest`
(real `NSEvent` click/drag through `StackView` asserting select/reorder + logic checks), and
CLI smoke tests (session files written/removed). Mirror those when changing interaction
handlers or the `--state` path.

## Architecture

Dual-mode, dispatched by `argv[1]` at the bottom of `main.swift`:
- **CLI mode** (`--state`, `--install-hooks`, `--uninstall-hooks`, `--statusline`, `--render*`,
  `--selftest`, `--status`, `--make-icon`, `--aititle`, `--meta`): does its work, `exit(0)`.
- **GUI mode** (no args): singleton `flock`, runs the `NSApplication` overlay.

**Data flow (no polling, no network):** a Claude Code hook runs `ClaudePet --state <s>`, which
reads the hook's JSON from **stdin** and writes one file per session to
`~/.claude-pet/sessions/<id>.json`; the GUI watches that folder (`AppDelegate.sync()` @0.25s),
reconciles, and animates. `off` deletes the file. `ensureRunning()` auto-launches the GUI.

**Overlay:** one `NSWindow` (contentView `StackView`). At rest it's **just the pet**. Hover (or
the *Keep Details Open* pin) reveals a **thought bubble** (status) above the pet and the
**session picker** below; both linger ~3s, then fade. The picker collapses to the active
session and expands on click (select / scroll-cycle / drag-reorder). `order` is stable; the
manual order + selection persist to `layout.json`. The panel height is dynamic
(`applyWindowFrame` grows the bubble up and picker down so the pet stays put).

**Companion data:**
- Hook payload → `detail`/`mode` on the session file (`detailFor`): tool verb+target while
  running, the notification reason, the StopFailure reason, compaction. Shown as pet-voice
  copy in the bubble (`pillText`: waiting→"answer Claude", done→"all done — your turn", etc.).
- Transcript tail → `SessionMeta` (session title for the picker; ctx tokens = gauge fallback).
  Full scan → `SessionTotals` (turns/tokens/cost/duration) for `--status` only.
- **Context gauge = the bubble's border** (green→amber→red). Exact % from the statusLine bridge
  file `$TMPDIR/claude-ctx-<id>.json` when present; else a token estimate (`contextLimitFor`
  infers 200k vs 1M). `--statusline` relays the exact % and we claim the `statusLine` slot
  **only if free or already ours** — never clobbering a user's own (e.g. GSD's).

## Three things that must stay in sync (cross-file coupling)

1. **`HOOK_WIRING`** — hook events → states. `installHooks()` writes them append-only and
   idempotently. Add/rename an event → update this table **and** the README hook table.
2. **`CODEX_ROW_SPECS`** — the 8×9, 192×208 Codex atlas contract (codex-pets.net compatible).
   Don't change unless intentionally breaking that compatibility.
3. **`describe(_:)`** — state → animation row + label + dot + one-shot fallback.

## Why the stdin/process handling is defensive (don't "simplify")

- `readHookInput()` polls stdin with a hard time cap so a hook never blocks the session.
- `ensureRunning()` spawns the GUI with `nullDevice` stdio so the hook doesn't wait on it.
- `acquireSingletonOrExit()` uses an exclusive `flock` so racing `--state` calls yield one GUI.

## Rendering

`PetView.draw` blits one cell from `~/.claude-pet/active.webp|png`; with no custom sprite it
falls back to `drawBuddy()` — the original mascot drawn entirely in code (also the app icon).
Code-drawn motion (bob/shake/halo/sleep) is **mascot-only**; a custom sprite renders flat and
animates from its own per-state frames. `Theme` colors are computed from the current `Palette`
(claude/midnight/grove/mono), so a theme switch recolors everything. The menu-bar icon
(`menuBarImage`) is a tiny state-colored pet; the ✳ dropdown is a live `NSMenuDelegate` panel.

## Conventions

- Branches: `main` (released), `dev` (integration). External PRs → `dev`. Both protected
  (PR + green `build` check; repo-admin `always` bypass). `scripts/setup-branch-protection.sh`.
- **Conventional Commits** (`feat:`/`fix:`/`feat!:`/`docs:`/`chore:`…) — the release version
  derives from them. Clean and professional, **NO AI attribution**.
- License **PolyForm Noncommercial** — keep art noncommercial-clean (mascot is drawn in code;
  never commit third-party sprites).

## Releasing (automatic) & keeping docs in sync

Push to `main` → `release.yml` computes the semver bump from Conventional Commits since the
last tag (`scripts/next-version.sh`) and, if there's something to ship, calls `build.yml` with
`release: true` → packages (`make-app.sh`; signs+notarizes when the `MACOS_*`/`APPLE_*` secrets
are present, else ad-hoc), tags `vX.Y.Z`, publishes the Release (`ClaudePet-macos.zip`).
`docs:`/`chore:`-only or `[skip release]` in the tip commit → no release. The app is its own
installer/uninstaller (no `.command` scripts): it self-wires hooks + the statusLine on launch
(self-healing the absolute path) and self-removes via **✳ → Uninstall**.

Treat docs as part of the change: touch `HOOK_WIRING` → README hook table; touch
states/animations/layout → README + this file + refresh screenshots (`--render` /
`--render-stack`); touch CLI flags → the Commands block above.
