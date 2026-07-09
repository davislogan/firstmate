#!/usr/bin/env bash
# Single owner for "what is this PR's current mergeable state, per GitHub".
# Resolves owner/repo from a project clone's origin remote (so callers only
# need a PR number, not a full URL, as long as they know which project clone
# the PR belongs to) and prints GitHub's mergeable_state - clean, dirty,
# unstable, blocked, behind, draft, or unknown - to stdout via `gh api`'s own
# --jq filtering (no separate jq dependency). "dirty" is GitHub's canonical
# signal that a PR now conflicts with its base branch; callers checking for a
# newly conflicted PR should compare against that value.
# Usage: fm-pr-mergeable.sh <project-dir> <pr-number>
set -eu

PROJECT_DIR=${1:?usage: fm-pr-mergeable.sh <project-dir> <pr-number>}
NUM=${2:?usage: fm-pr-mergeable.sh <project-dir> <pr-number>}

REMOTE=$(git -C "$PROJECT_DIR" remote get-url origin 2>/dev/null) || {
  echo "fm-pr-mergeable: no origin remote in $PROJECT_DIR" >&2
  exit 1
}
OWNER_REPO=$(printf '%s' "$REMOTE" | sed -E 's#^git@github\.com:##; s#^https://github\.com/##; s#\.git$##')
case "$OWNER_REPO" in
  */*) ;;
  *)
    echo "fm-pr-mergeable: could not parse owner/repo from origin remote: $REMOTE" >&2
    exit 1
    ;;
esac

gh api "repos/$OWNER_REPO/pulls/$NUM" --jq '.mergeable_state'
