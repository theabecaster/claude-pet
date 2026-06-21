# Contributing to Claude Pet

Thanks for your interest! Forks, bug reports, and pull requests are welcome.

## Ground rules

- This project is licensed under **PolyForm Noncommercial 1.0.0**. By
  contributing, you agree your contributions are provided under the same
  license. Noncommercial use, forks, and improvements are encouraged;
  commercial/monetized use is not permitted.
- Be kind. Keep discussion focused on the code.

## Branches

- `main` — stable, released code. Protected; changes land via PR.
- `dev` — integration branch. **Open pull requests against `dev`.**

## Development

```bash
swift build -c release
.build/release/ClaudePet --render running /tmp/p.png   # offscreen preview of a state
.build/release/ClaudePet &                             # run the overlay
.build/release/ClaudePet --state waiting               # simulate a hook
```

Package the distributable app bundle:

```bash
bash scripts/make-app.sh 1.0.0     # -> dist/ClaudePet.app + installers
```

## Pull requests

1. Fork and branch from `dev`.
2. Keep changes focused; match the existing code style.
3. Make sure `swift build -c release` is clean (no warnings).
4. Describe what you changed and why. Screenshots help for visual changes.

## Releases

Tagging `vX.Y.Z` on `main` triggers CI to build, package, and attach
`ClaudePet-macos.zip` to a GitHub Release.
