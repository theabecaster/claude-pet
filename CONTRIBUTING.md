# Contributing to Claude Pet

Thanks for your interest! Forks, bug reports, and pull requests are welcome.

## Ground rules

- This project is licensed under **PolyForm Noncommercial 1.0.0**. By
  contributing, you agree your contributions are provided under the same
  license. Noncommercial use, forks, and improvements are encouraged;
  commercial/monetized use is not permitted.
- Be kind. Keep discussion focused on the code.

## Branches

- `main` — stable, released code. Protected by a ruleset: no direct pushes,
  changes land via PR, CI (`build`) must be green, and force-push/deletion are
  blocked. Every merge to `main` auto-cuts a release (see below).
- `dev` — integration branch. Also protected (PR + green CI, no force-push/delete).
  **Open pull requests against `dev`.**

(The maintainer holds an admin bypass on both branches; outside contributors fork
and open PRs.)

## Commit messages (Conventional Commits)

Releases are versioned automatically from commit messages, so prefix them:

- `fix: …` / `perf: …` → patch bump (1.9.0 → 1.9.1)
- `feat: …` → minor bump (1.9.0 → 1.10.0)
- `feat!: …` or a `BREAKING CHANGE:` footer → major bump (1.9.0 → 2.0.0)
- `docs:` / `chore:` / `ci:` / `refactor:` / `test:` → no release

Add `[skip release]` to a commit subject to suppress a release even if it would
otherwise bump. Scopes are allowed: `fix(menu): …`.

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
4. Use Conventional Commit messages (see above) so versioning works.
5. Describe what you changed and why. Screenshots help for visual changes.

A PR needs **1 approval** and a green `build` check before it can merge.

## Releases

Releases are **automatic**. When `main` advances (a PR merges, or the maintainer
pushes directly), the `release` workflow computes the next version from the
Conventional Commits since the last tag, then builds, signs, notarizes, tags
`vX.Y.Z`, and publishes `ClaudePet-macos.zip` to a GitHub Release.

Preview what the next push would cut:

```bash
bash scripts/next-version.sh     # prints release=<bool> and version=X.Y.Z
```

Manual escape hatches (rarely needed): run the `release` workflow from the
Actions tab with an explicit version (`gh workflow run release.yml -f version=1.2.3`),
or push a tag (`git tag v1.2.3 && git push origin v1.2.3`).
