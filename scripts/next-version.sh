#!/usr/bin/env bash
# Computes the next semver release from Conventional Commits since the last vX.Y.Z tag.
#
# Prints exactly two lines (GITHUB_OUTPUT-friendly):
#   release=<true|false>
#   version=<X.Y.Z>
#
# Bump rules (highest match wins) over commits since the last tag:
#   - major : a subject typed with `!` (e.g. `feat!:`/`fix(x)!:`) or a `BREAKING CHANGE` body
#   - minor : any `feat:` / `feat(scope):`
#   - patch : any `fix:`/`perf:` (with optional scope)
#   - none  : anything else  -> release=false (e.g. docs/chore/ci/refactor/test only)
#
# release=false is also forced when the tip commit message contains a skip marker:
#   [skip release] | [release skip] | [no release]
#
# Run locally to preview what a push to main would cut:
#   bash scripts/next-version.sh
set -euo pipefail

last="$(git tag -l 'v*' --sort=-v:refname | head -n1)"

if [ -n "$last" ] && git merge-base --is-ancestor "$last" HEAD 2>/dev/null; then
  range="${last}..HEAD"
else
  # No tag yet, or the latest tag isn't on this history: consider all commits.
  range="HEAD"
fi

base="${last#v}"; base="${base:-0.0.0}"
IFS=. read -r major minor patch <<EOF
$base
EOF
major="${major:-0}"; minor="${minor:-0}"; patch="${patch:-0}"

# Skip marker on the tip commit (docs typos, infra tweaks, etc.).
if git log -1 --format='%B' | grep -qiE '\[(skip release|release skip|no release)\]'; then
  echo "release=false"
  echo "version=${base}"
  exit 0
fi

subjects="$(git log "$range" --format='%s' 2>/dev/null || true)"
bodies="$(git log "$range" --format='%B' 2>/dev/null || true)"

bump=""
if printf '%s\n' "$subjects" | grep -qE '^[a-zA-Z]+(\([^)]*\))?!:' \
   || printf '%s\n' "$bodies" | grep -qE 'BREAKING[ -]CHANGE'; then
  bump=major
elif printf '%s\n' "$subjects" | grep -qE '^feat(\([^)]*\))?:'; then
  bump=minor
elif printf '%s\n' "$subjects" | grep -qE '^(fix|perf)(\([^)]*\))?:'; then
  bump=patch
fi

case "$bump" in
  major) major=$((major + 1)); minor=0; patch=0 ;;
  minor) minor=$((minor + 1)); patch=0 ;;
  patch) patch=$((patch + 1)) ;;
  *)
    echo "release=false"
    echo "version=${base}"
    exit 0
    ;;
esac

echo "release=true"
echo "version=${major}.${minor}.${patch}"
