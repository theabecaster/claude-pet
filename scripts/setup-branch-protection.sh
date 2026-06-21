#!/usr/bin/env bash
# (Re)applies GitHub branch-protection rulesets for `main` and `dev`, idempotently.
#
# Each ruleset:
#   - requires a pull request before merging with 1 approval (override with
#     REQUIRED_APPROVALS=0 to make a PR mandatory but self-mergeable),
#   - requires the `build` status check to pass,
#   - blocks force-pushes and branch deletion,
#   - grants an `always` bypass to the repository **admin** role (actor_id 5),
#     so the maintainer keeps direct push access while everyone else must PR.
#
# Safe to re-run: updates the ruleset in place if one with the same name exists.
# Requires: gh (authenticated with `repo` scope).
#
#   bash scripts/setup-branch-protection.sh
set -euo pipefail

REPO="${REPO:-theabecaster/claude-pet}"
REQUIRED_APPROVALS="${REQUIRED_APPROVALS:-1}"
BRANCHES=(main dev)

ruleset_json() {
  local branch="$1"
  cat <<JSON
{
  "name": "protect-${branch}",
  "target": "branch",
  "enforcement": "active",
  "conditions": { "ref_name": { "include": ["refs/heads/${branch}"], "exclude": [] } },
  "bypass_actors": [
    { "actor_id": 5, "actor_type": "RepositoryRole", "bypass_mode": "always" }
  ],
  "rules": [
    { "type": "deletion" },
    { "type": "non_fast_forward" },
    { "type": "pull_request", "parameters": {
        "required_approving_review_count": ${REQUIRED_APPROVALS},
        "dismiss_stale_reviews_on_push": false,
        "require_code_owner_review": false,
        "require_last_push_approval": false,
        "required_review_thread_resolution": false
    } },
    { "type": "required_status_checks", "parameters": {
        "strict_required_status_checks_policy": false,
        "required_status_checks": [ { "context": "build" } ]
    } }
  ]
}
JSON
}

for branch in "${BRANCHES[@]}"; do
  name="protect-${branch}"
  existing_id="$(gh api "repos/${REPO}/rulesets" --jq ".[] | select(.name==\"${name}\") | .id" 2>/dev/null || true)"
  if [ -n "$existing_id" ]; then
    echo "==> Updating ruleset ${name} (id ${existing_id})"
    ruleset_json "$branch" | gh api -X PUT "repos/${REPO}/rulesets/${existing_id}" --input - >/dev/null
  else
    echo "==> Creating ruleset ${name}"
    ruleset_json "$branch" | gh api -X POST "repos/${REPO}/rulesets" --input - >/dev/null
  fi
done

echo "==> Done. Current rulesets:"
gh api "repos/${REPO}/rulesets" --jq '.[] | "  \(.id)  \(.name)  [\(.enforcement)]"'
