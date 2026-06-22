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
.build/release/ClaudePet --render-menubar /tmp/m.png   # preview the menu-bar icon (each state, dark+light bar)
.build/release/ClaudePet --status                      # terminal health + live session report (read-only)
.build/release/ClaudePet --statusline                  # statusLine command: relays exact context % to the bridge file (hook-invoked)
.build/release/ClaudePet --selftest                    # drive real NSEvent click/drag through handlers + logic checks (CI gate)
.build/release/ClaudePet --make-icon /tmp/icon.png      # render the app icon
.build/release/ClaudePet --aititle /path/to/transcript.jsonl   # debug AI-title parsing
.build/release/ClaudePet --meta /path/to/transcript.jsonl      # debug transcript meta (title/model/context/branch)

./install.sh                                            # build + wire hooks (dev install)
bash scripts/make-app.sh 1.0.0                          # package dist/ClaudePet.app + installers
./load-pet.sh /path/to/spritesheet.webp                 # swap in a custom sprite
bash scripts/next-version.sh                            # preview next auto-release version from commits
bash scripts/setup-branch-protection.sh                 # (re)apply main/dev branch-protection rulesets
```

There is no unit-test suite. CI (`.github/workflows/build.yml`) is the de-facto test: it
builds release, runs **`--selftest`** (fires real `NSEvent` click/drag through the StackView
handlers and asserts select/reorder behavior), and runs CLI smoke tests asserting per-session
state files are written/removed correctly. Mirror those assertions when changing the
interaction handlers or the `--state` / hook-routing path. CI also requires a clean build with
**no warnings** (see CONTRIBUTING.md).

## Architecture

The binary is **dual-mode**, dispatched by `argv[1]` at the bottom of `main.swift`:

- **CLI mode** (`--state`, `--install-hooks`, `--uninstall-hooks`, `--statusline`, `--render`,
  `--render-stack`, `--render-menubar`, `--selftest`, `--status`, `--make-icon`, `--aititle`,
  `--meta`): does its work and `exit(0)` — never starts the GUI event loop.
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
pet stays put. A live reorder mutates `StackView.items` immediately but only commits to `order`
(via `onReorder`) on mouseUp; `sync()` must therefore skip its `stack.items` rebuild while
`stack.isReordering` is true — otherwise the 0.25s timer reverts `items` to the uncommitted
`order` mid-drag and the grabbed row snaps back onto the row you hovered. A single session
hides the list and just shows the pet with its name.

The user's manual arrangement (`order` + `selectedID`) is persisted to
`~/.claude-pet/layout.json` and restored on launch (stale ids pruned in `sync()`), so it
survives overlay restarts.

### Surfacing what Claude Code exposes (the companion data)

The pet shows *what* a session is doing and *why* it stopped, from two sources — no
polling, no network:

- **Hook payload → `detail`/`mode`.** `readHookInput()` returns a `HookInput` (session/cwd/
  transcript/source **plus** `hook_event_name`, `tool_name`, `tool_input`, `message`,
  `error_type`, `permission_mode`, `trigger`). `writeState()` calls `detailFor(state:_:)` to
  fold the payload into one short string stored on the session file: a tool **verb + target**
  for running states (`toolVerb()`: Edit→"editing", Bash→"running", Grep/Glob→"searching",
  WebFetch→"browsing", Task→"delegating", mcp__*→"calling tool"…; `toolTarget()` adds the
  file basename / first command word / quoted pattern / url host → "editing main.swift"),
  the **Notification message** for `waiting`, the humanized **StopFailure reason** for
  `failed` (`errorReason()`: rate_limit→"rate limited"…), and "compacting context" for the
  **PreCompact** event. It also stores a non-default `permission_mode` as `mode` (surfaced via
  `modeBadge()`: plan/auto-edits/bypass). The pill shows `detail` in place of the bare state
  label when present.
- **Transcript tail → `SessionMeta`.** `readTranscriptMeta()` does ONE tail read (128 KB)
  and extracts the title (ai-title/custom-title, same precedence as before), the latest
  `assistant.message.model`, the current **context size** (`input + cache_read +
  cache_creation` tokens of the latest complete assistant record), and the **gitBranch**.
  `readAITitle()` now just calls it. The GUI caches a `SessionMeta` per session in
  `metaCache` keyed by transcript mtime; `metaLine()` formats `model · Nk ctx · branch ·
  mode` (humanized by `shortModel()` / `compactTokens()` / `modeBadge()`, mode omitted when
  default), drawn dim under the caption.
- **Transcript FULL scan → `SessionTotals`.** `readTranscriptTotals()` reads the whole
  file once to sum turns / input / output / cache tokens, an **estimated cost**
  (`modelPrices()` per-MTok table × usage), and the active span (first→last `timestamp`).
  Heavier than the tail scan, so it's only used on demand — `--status` and not the 4 Hz
  overlay loop. `compactUSD()` formats the estimate.
- **statusLine bridge → EXACT context %.** Claude Code hands the true context window
  (200k vs the 1M beta, already as a percentage) ONLY to its `statusLine` command, never to
  hooks — so the transcript-token gauge above is only an estimate (it infers the window via
  `contextLimitFor()`). To get exact, we register our own `statusLine` (`--statusline` →
  `statusLine()`): it reads CC's piped JSON, takes `context_window.used_percentage` (falling
  back to computing it from `current_usage` ÷ `context_window_size`), and relays it to
  `$TMPDIR/claude-ctx-<session>.json` (`{used_pct, timestamp}`). `bridgeContextUsed()` reads
  that file when fresh (<1h); `sync()` prefers it over the token estimate (`main.swift`,
  ctxProgress branch). The statusLine also prints a short `🐾 dir · model · N% ctx` line,
  since claiming the slot makes it the user's statusline. **It's a SINGLE slot** (unlike the
  hooks list), so `installStatusLineInto()` claims it **only when empty or already ours** —
  it never clobbers a user's existing statusline (e.g. GSD's, which already writes the same
  bridge). `installHooks()` and the GUI launch path both call it (self-healing the absolute
  exe path); `uninstallHooks()`/uninstall-self drop it only if it's ours. `--status` reports
  the state (`statusLineState()`: ours / user's own / none).

The selected `PetView` stacks **pet → pill (`detail`/label + `· elapsed`) → caption
(title) → meta line → context gauge**. `elapsedText` is **time-in-state**:
`AppDelegate.stateSince[id]` is stamped whenever a session's state changes;
`compactElapsed()` renders it. `ctxFraction` (= ctx tokens / `prefs.contextBudget`) drives
`drawGauge()` — a thin bar that runs green, amber past 75%, red past 90%. List rows show
each session's `detail` on the right (dim) in place of the bare status word. `PETH` (192)
fits the meta line + gauge.

The built-in mascot **dozes off** after ~45s idle (`PetView.idleTicks > sleepAfterTicks`,
mascot-only like the other code-drawn motion): `drawBuddy(sleeping:)` draws closed eyes +
calm mouth, `motion()` switches to a slow breathing bob, and `drawZzz()` floats a few `z`s.

### Preferences, themes, alerts, and the pet-tap

- **`Prefs`** (`~/.claude-pet/prefs.json`, loaded at launch, saved on every toggle): theme
  id, `soundOnAttention`, `bounceOnAttention`, `muted`, `showMeta`, `showElapsed`,
  `contextBudget` (gauge denominator), `renudge`. All fields are optional-with-defaults so
  older files keep decoding. `applyToGlobals()` pushes the theme into `Theme.current`. The
  **✳ menu is rebuilt** (`rebuildMenu()`) after each change so checkmarks/theme dots/budget
  dots stay in sync; `commitPrefs()` saves + rebuilds.
- **Themes** are `Palette`s (`claude`/`midnight`/`grove`/`mono`). `Theme` is no longer a
  bag of `static let`s — `Theme.coral`/`termBG`/… are computed from `Theme.current`, so a
  theme switch recolors **everything** (pet, pills, rows, menu-bar icon) on the next
  redraw. Add a palette to `Palette.all` and it appears in the Theme submenu automatically.
- **Attention alerts.** `sync()` tracks `prevStates[id]`; on a transition INTO an attention
  state (`waiting`/`failed`, not from another attention state) it calls
  `fireAttentionAlert()` — an `NSSound` chime and `requestUserAttention` bounce, each
  gated by prefs and debounced. `didInitialSync` suppresses alerts for sessions already
  present at launch (no startup spam). While a session keeps waiting, the steady-state
  branch **re-nudges** every `RENUDGE_SECONDS` (gated by `prefs.renudge`, tracked via
  `lastNudge[id]`). No `UNUserNotificationCenter` — it would need entitlements the accessory
  binary can't rely on; sound + bounce work unconditionally.
- **Global hotkey.** `registerHotKey()` uses Carbon `RegisterEventHotKey` (⌃⌥⌘P → toggle
  show/hide) — works for an accessory app with no extra entitlements or accessibility grant,
  unlike a global `NSEvent` monitor. The C handler hops to the main queue and calls
  `toggleVisibility()`.
- **Pet-tap.** A non-drag tap landing inside `primary.frame` fires `StackView.onPetTapped`
  → `PetView.poke()`: a one-shot happy hop (`pokeUntil` adds a decaying bounce to the
  mascot's `motion()`) that settles back to `baseState` (the real session state) via the
  existing one-shot-fallback machinery.

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

The code-drawn **attention effects** (`motion()`'s bob/shake + the pulsing halo) are gated to
the built-in mascot only: `draw()` uses `sprite == nil ? motion() : (0,0,0)`, so a **custom
sprite renders flat** and animates purely from its own per-state frames — preserving the look
its author intended in every state. The default mascot keeps its full attention-budget motion.
(The status pill/caption are informational chrome and render for both.)

The **menu-bar icon** is a tiny version of the same pet (`menuBarImage()`), reflecting the
selected session's state so the app stays usable when the overlay is hidden. It's colored by
state (`accentFor`) rather than a dark template — a custom sprite blits its first frame for the
state; the default mascot is drawn as a solid accent-filled `drawBuddy()` (via the `bodyFill`
param) so it stays legible on both light and dark menu bars. `AppDelegate.updateMenuBarIcon()`
re-renders only when the state or sprite changes (keyed by `menuIconKey`); `sync()` drives it
and `reloadSprite()` invalidates it.

The **menu-bar dropdown is a live status panel.** `AppDelegate` is the menu's
`NSMenuDelegate`; `menuNeedsUpdate(_:)` calls `populate(_:)` to rebuild it in place each time
it opens, so the top **Sessions** section always lists the current sessions (state dot-pet +
name + what each is doing) — click one (`selectSession`) to make it the big pet (and un-hide
the overlay). Below it sit the theme submenu, the pref toggles (live checkmarks), and the
pet/hook/uninstall actions. Toggles repopulate the same menu object via `rebuildMenu()`.

Session labels come from the transcript JSONL, parsed by `readAITitle()` from its tail: a
user's manual rename (`"type":"custom-title"`, field `customTitle`) wins over Claude Code's
AI-generated title (`"type":"ai-title"`, field `aiTitle`); for each kind the latest wins.
They fall back to the project folder name (`label()`). Renames propagate live because
`sessionTitle()` re-reads when the transcript's mtime changes. The selected pet's caption (shown for single
*and* multi) wraps to two lines via `PetView.wrapCaption`; list rows single-line truncate.

**`/clear` resets the name.** A clear reuses the same `session_id` but starts a fresh
conversation, and Claude Code re-asserts the *pre-clear* custom title into the new transcript
(repeatedly, with no timestamp to tell carried-over from fresh). So `writeState()` records a
sticky `cleared` flag on the session file when the `SessionStart` hook's `source == "clear"`
(read by `readHookInput()`), and `sessionTitle()` calls `readAITitle(_, ignoreCustom:)` for
cleared sessions — dropping the manual rename so the name falls back to a fresh `ai-title` or
the folder name. The flag persists across later state writes and dies with the session file on
`SessionEnd`. (Tradeoff: a *new* manual rename after a clear is also ignored — acceptable,
since the records are indistinguishable.)

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

- Branches: `main` is stable/released; `dev` is the integration branch the maintainer works
  on day-to-day. **External contributors open PRs against `dev`** (per CONTRIBUTING.md). Both
  branches are protected by **GitHub rulesets** (`gh api repos/:owner/:repo/rulesets`): direct
  pushes are blocked, changes need a PR, the `build` CI check must pass, and force-push +
  deletion are blocked. The maintainer (repo **admin**) has an `always` bypass on both, so they
  can still push directly; everyone else must PR (collaborators) or fork+PR (outside). To edit
  the rules: `gh api repos/theabecaster/claude-pet/rulesets/<id>` (GET to inspect, PUT to update,
  DELETE to remove).
- **Commit messages: Conventional Commits** (`feat:`/`fix:`/`feat!:`/`docs:`/`chore:`…) — the
  release version is derived from them (see below). Still **clean and professional, NO AI
  attribution** — never mention Claude / Anthropic / "Generated with…" / "Co-Authored-By:
  Claude". (Global user rule.)
- License is PolyForm Noncommercial — keep any bundled/added art noncommercial-clean (the
  mascot/icon are drawn in code on purpose; never commit third-party sprites).

## Release & maintenance procedures

We ship a single distributable: the prebuilt, signed + notarized **`ClaudePet.app`** alone,
zipped as `ClaudePet-macos.zip` and attached to a GitHub Release. **No `.command` installer
scripts** — a downloaded script is always quarantine-gated, so the app installs and uninstalls
itself instead (see below). Versioning is **semver**, **derived automatically from Conventional
Commit messages** — there is no manual tagging in the normal flow. The computed version becomes
the `vX.Y.Z` tag and the bundle's `CFBundleShortVersionString`.

### How releasing works (automatic)

Two workflows, one engine:
- **`build.yml`** — the reusable build engine + CI. Runs `swift build`, `--selftest`, and the
  CLI smoke tests on every PR (to `main`/`dev`) and push to `dev`; its `build` job is the
  required status check. Also exposes `workflow_call(release, version)` — when `release: true`
  it additionally packages, signs, notarizes, tags `vX.Y.Z`, and publishes the GitHub Release.
- **`release.yml`** — fires on **push to `main`** (a PR merge or a maintainer push). Its
  `version` job runs `scripts/next-version.sh` to compute the bump from Conventional Commits
  since the last tag, then calls `build.yml` with `release: true` only if there's something to
  ship. (`main` is intentionally **not** a `push` trigger in `build.yml`, so a merge builds
  once, not twice.)

**Version rules** (`scripts/next-version.sh`, runnable locally to preview):
- `fix:`/`perf:` → patch · `feat:` → minor · `feat!:` or `BREAKING CHANGE:` → major
- `docs:`/`chore:`/`ci:`/`refactor:`/`test:`-only, or **`[skip release]`** in the tip commit
  → **no release** (this replaces the old "docs-only = no tag" rule).

So the **standard flow is just**: land Conventional-Commit-prefixed work on `main` (PR from
`dev`, or a direct maintainer push). Everything below happens automatically.

1. **Before merging**, the gates run in CI but mirror them locally when iterating:
   ```bash
   swift build -c release 2>&1 | grep -i warning   # must be empty
   .build/release/ClaudePet --selftest             # interaction gate (exit 0)
   bash scripts/next-version.sh                     # preview release=<bool> version=X.Y.Z
   ```
2. **Keep docs in sync in the SAME change** (see "Docs to update" below). Regenerate any
   affected screenshots with `--render <state> docs/pet_<state>.png`, `--render-stack
   docs/stack.png`, and the icon with `make-icon.sh`.
3. **The release job** (inside `build.yml`, triggered by `release.yml`) runs
   `bash scripts/make-app.sh <version>` → `dist/ClaudePet.app`. The script **code-signs** the
   bundle and runs `codesign --verify` (a hard gate): the Swift linker leaves a partial,
   inconsistent signature (no `CodeResources`), which a quarantined app reports as "damaged —
   move to Trash". With the Developer ID secrets present it signs with the real identity +
   hardened runtime + secure timestamp, then **notarizes and staples** — removing the Gatekeeper
   prompt entirely. (Locally / without secrets, `make-app.sh` signs **ad-hoc**, downgrading the
   fatal verdict to the recoverable "unidentified developer → Open Anyway".)

   **Notarization secrets** (GitHub repo → Settings → Secrets and variables → Actions). When
   absent (PRs, forks) CI falls back to ad-hoc and still passes:
   - `MACOS_CERTIFICATE` — base64 of the exported **Developer ID Application** cert `.p12`
     (`base64 -i cert.p12 | pbcopy`).
   - `MACOS_CERTIFICATE_PWD` — the password set when exporting the `.p12`.
   - `KEYCHAIN_PWD` — any throwaway string (temp keychain password in CI).
   - `APPLE_ID` — Apple ID email of the Developer account.
   - `APPLE_TEAM_ID` — 10-char Team ID (Apple Developer → Membership).
   - `APPLE_APP_PASSWORD` — an **app-specific password** (appleid.apple.com → Sign-In & Security),
     not the account password.
4. **Verify after merge:** `gh run list --workflow release.yml -L 3` shows success, and
   `gh release view vX.Y.Z` lists `ClaudePet-macos.zip`.

**Manual escape hatches** (rarely needed):
- Force a specific version: `gh workflow run release.yml -f version=X.Y.Z` (or Actions tab →
  release → Run workflow).
- Push a tag: `git tag vX.Y.Z && git push origin vX.Y.Z` — `release.yml`'s tag trigger picks
  it up and publishes. (Tags created by CI's `GITHUB_TOKEN` don't re-trigger workflows, so the
  auto-flow never loops.)

**(Optional) dogfood locally** — reinstall the running copy without it hanging:
```bash
bash scripts/make-app.sh "$(bash scripts/next-version.sh | sed -n 's/^version=//p')"
pkill -x ClaudePet; sleep 1; pkill -9 -x ClaudePet
rm -f ~/.claude-pet/pet.lock ~/.claude-pet/pet.pid
rm -rf /Applications/ClaudePet.app && cp -R dist/ClaudePet.app /Applications/ClaudePet.app
/Applications/ClaudePet.app/Contents/MacOS/ClaudePet --install-hooks < /dev/null
```

### Branch protection (rulesets)

`main` and `dev` each have a ruleset requiring a PR, the `build` status check, and blocking
force-push + deletion — with an `always` **bypass for the repo admin role** so the maintainer
can push directly. PRs need **1 approval** to merge (the admin bypass exempts the maintainer). They are defined and
re-applied by **`scripts/setup-branch-protection.sh`** (idempotent; re-run after changing the
rules, or set `REQUIRED_APPROVALS=0` to make PRs self-mergeable). To inspect/modify by hand: `gh api repos/theabecaster/claude-pet/rulesets`
(list), `…/rulesets/<id>` (GET/PUT/DELETE).

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

The zip contains **only the notarized `ClaudePet.app`** — drag to `/Applications`, open. Released
builds are **signed with a Developer ID and notarized** (when the CI secrets are configured), so
they launch with no Gatekeeper prompt. **The app is its own installer**: on launch the GUI calls
`hooksPointToSelf()` and runs `installHooks()` if the hooks are missing or point at a different
path (so moving the app self-heals the absolute hook path). The **✳ menu** exposes *Theme ▸*
(`pickTheme`), the alert/info toggles (`toggleSound`/`toggleBounce`/`toggleMuted`/`toggleMeta`/
`toggleElapsed` — all routed through `commitPrefs()`), *Get Custom Pets (codex-pets.net)…*
(`browseCustomPets` — opens the gallery in the browser and spells out the download → *Load
Pet…* flow), *Reinstall Claude Code Hooks* (`reinstallHooks`) and
*Uninstall Claude Pet…* (`uninstallSelf` — unwires hooks, deletes `~/.claude-pet`, removes the
bundle, quits). We deliberately ship **no `.command`
scripts**: a downloaded script is always quarantine-gated, which defeated the old installer. If a
build ever ships only ad-hoc-signed (secrets missing), the app still launches but hits the
recoverable "unidentified developer → Open Anyway" prompt — not the fatal "damaged — move to
Trash" of an unsigned/partially-signed bundle; `xattr -dr com.apple.quarantine <app>` clears it.
