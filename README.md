<p align="center"><img src="docs/icon.png" width="120" alt="Claude Pet icon"></p>
<h1 align="center">Claude Pet</h1>

<p align="center">
  A floating desktop companion for <b>Claude Code</b> that mirrors your session
  state in real time — like Codex Pets, but for Claude Code, in the Claude
  terminal aesthetic, and <b>compatible with Codex pet sprites</b>.
</p>

<p align="center">
  <img src="docs/pet_running.png" width="150" alt="working">
  <img src="docs/pet_waiting.png" width="150" alt="needs you">
  <img src="docs/pet_review.png" width="150" alt="ready">
</p>
<p align="center"><sub>The built-in mascot (original art) reacting to session state. Load any Codex pet to replace it.</sub></p>

---

## What it does

A small animated pet sits in the corner of your screen — above every app and
across all Spaces — and reacts to what Claude Code is doing. Glance at it
instead of switching back to the terminal.

## Codex-compatible sprites 🎉

Claude Pet renders the **exact Codex pet atlas**: an `8×9` grid of `192×208`
cells (`1536×1872` WebP), with all **9 animation states**. That means **any pet
from [codex-pets.net](https://codex-pets.net) or the `hatch-pet` skill drops
straight in** — `spritesheet.webp` and all.

## Session state → animation

Every Codex state is wired to a real Claude Code hook:

| Codex state     | Claude Code hook        | Meaning                        | Pill        |
|-----------------|-------------------------|--------------------------------|-------------|
| `waving`        | `SessionStart`          | session begins (→ idle)        | `● hello`   |
| `running-right` | `UserPromptSubmit`      | new turn starts                | `● working` |
| `running`       | `PreToolUse`            | actively working               | `● working` |
| `running-left`  | `PostToolUse`           | step finished                  | `● working` |
| `waiting`       | `Notification` / `PermissionRequest` | needs your input  | `● needs you` |
| `jumping`       | `Stop`                  | turn done (→ review)           | `● done!`   |
| `review`        | (after `Stop`)          | ready for your next prompt     | `● ready`   |
| `failed`        | `StopFailure`           | the turn errored               | `● error`   |
| `idle`          | (after `waving`)        | at rest                        | —           |

Each hook writes `~/.claude-pet/sessions/<session_id>.json`; the overlay watches
the folder and animates. `waving` and `jumping` are one-shots that settle into
`idle` and `review`. No polling of Claude, no network.

## Calm by design

The animation follows an **attention budget**: when Claude is *working*, the pet
stays still and just looks busy (a slow typing cursor) so it never distracts you.
When it **needs you** it gets your attention — a gentle bob and a pulsing halo —
then settles down again once handled. `ready` gives a soft positive nudge,
`error` a small shake. Calm while you work; loud only when it matters.

These code-drawn effects (bob, shake, halo) belong to the **built-in mascot**. A
**custom sprite** renders flat and animates purely from its own frames, so it keeps
exactly the look and motion its author designed in every state.

## Lives in your menu bar too

The menu-bar icon is a **tiny version of your pet**, colored by the selected
session's state — coral at rest, green while working/ready, red when it needs you
or errors. It reads clearly in both light and dark menu bars, so even with the
overlay hidden (**✳ → Show / Hide**) you can still glance up and see what Claude
is doing.

## Multiple sessions — one tidy stack

<p align="center"><img src="docs/stack.png" width="240" alt="Multi-session stack: selected pet with a list of sessions above it"></p>

Run several Claude Code sessions at once and you get **one cohesive stack**, not a
mess of windows. The **selected** session shows as the big pet in the corner; all
your sessions appear in a clean list above it, in a **stable order that never
shuffles on its own**. Each row shows the session's **title** — the same name
Claude Code shows in its session list, so renaming a session there renames its
pet too (falls back to the AI-generated title, then the project folder) — and a
color-coded status, so you can see at a glance which one needs you.

You're in control:

- **Click a session** to select it — its pet becomes the big one (the row gets a
  highlighted *selected* state). The order doesn't change.
- **Scroll** over the widget to step the selection through sessions.
- **Drag a row** up or down to reorder the list however you like.
- **Drag the pet** (or empty space) to move the whole widget; it stays where you
  put it.

Sessions appear when they start and disappear when they end (stale ones are
pruned). A **single session** is just the one pet with its name shown beneath.

## Install

### Easy (no terminal — for everyone)

1. Download `ClaudePet-macos.zip` from the [latest release](../../releases/latest).
2. Unzip, then **run `Install Claude Pet.command`** — don't double-click `ClaudePet.app`
   directly. The installer copies the app to `/Applications`, clears the download
   quarantine, and wires the hooks for you.
   - First run macOS asks to confirm a downloaded script: **right-click → Open → Open**.
3. Restart Claude Code. Your pet appears and reacts.

Control it from the **✳ menu-bar icon**: show/hide, load a pet, reset to default.

> **“ClaudePet.app is damaged / can’t be opened”?** That’s macOS Gatekeeper, not a
> broken download. Run **`Install Claude Pet.command`** (it clears the flag for you),
> or clear it manually:
> ```bash
> xattr -dr com.apple.quarantine /path/to/ClaudePet.app
> ```

### One-click (for technical friends)

```bash
git clone https://github.com/theabecaster/claude-pet.git
cd claude-pet && ./install.sh
```

Builds and wires hooks (non-destructive — your existing hooks are preserved).

## Load a custom pet

- **Menu bar → ✳ → Load Pet…** and pick a Codex `spritesheet.webp`, a `.png`
  sheet, or a whole pet folder, **or**
- `./load-pet.sh https://codex-pets.net/assets/pets/v/…/spritesheet.webp`
- `./load-pet.sh /path/to/petfolder`  (folder containing `spritesheet.webp`)

Reset anytime with **✳ → Reset to Default Pet**. Using a non-Codex sheet?
Override the grid in `~/.claude-pet/frames.json` (see
[`frames.json.example`](frames.json.example)).

> Pets you download are the property of their creators — use art you're allowed
> to use.

## How it works

```
Claude Code ──hook──▶ ClaudePet --state <s> ──▶ ~/.claude-pet/state.json
                                                        │ (watched)
                                          ClaudePet GUI ◀┘  animates overlay
```

One tiny Swift binary. `--state` writes the file and auto-launches the GUI if it
isn't running (single-instance via pidfile). `--install-hooks` /
`--uninstall-hooks` edit `~/.claude/settings.json` **non-destructively and
idempotently**.

## Uninstall

Double-click **`Uninstall Claude Pet.command`**, or:

```bash
.build/release/ClaudePet --uninstall-hooks
pkill -f ClaudePet
rm -rf ~/.claude-pet /Applications/ClaudePet.app
```

## Requirements

macOS 12+ (WebP decoding is built in). Swift / AppKit, no runtime deps.

## Contributing

Forks, issues, and PRs welcome — open PRs against `dev`. See
[CONTRIBUTING.md](CONTRIBUTING.md).

## License

[PolyForm Noncommercial 1.0.0](LICENSE). Use, modify, fork, and share for any
**noncommercial** purpose. You may **not** sell it or use it commercially.
