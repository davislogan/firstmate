#!/usr/bin/env bash
# fm-pr-rebase.sh - pure git mechanics for rebasing a PR head branch onto the
# freshly updated default branch, in a disposable scratch clone that never
# touches the project clone, any crew worktree, or anything under projects/.
#
# <project-dir> is a local clone whose `origin` remote points at the repo the
# PR lives in. The scratch clone is created FROM that local clone (cheap, and
# read-only toward it), then re-pointed at the real origin URL, so the fetch
# and the push talk to the authoritative remote while most objects come from
# local disk.
#
# The push uses --force-with-lease pinned to the exact head OID fetched at the
# start, so a concurrent push - a live crew, or no-mistakes' own CI-monitor
# auto-rebase - makes this push fail cleanly instead of clobbering anything.
# This script never plain-forces, never resolves a content conflict, and on
# any failure leaves the remote branch untouched.
#
# stdout on success:          rebased onto <default>: <old-oid> -> <new-oid>
# stdout on content conflict: conflict: <file> [<file>...]
# Exit codes: 0 = rebased and pushed; 2 = genuine content conflict (rebase
# aborted, remote untouched); 1 = mechanical failure (no origin, unreachable
# remote, missing branch, lease race; remote untouched).
#
# Deliberately gh-free and state-free: fm-pr-autoheal.sh owns status/meta
# writes, and pure git keeps this end-to-end testable against local bare
# origins (tests/fm-pr-rebase.test.sh).
# Usage: fm-pr-rebase.sh <project-dir> <head-branch>
set -eu

PROJECT_DIR=${1:?usage: fm-pr-rebase.sh <project-dir> <head-branch>}
HEAD_BRANCH=${2:?usage: fm-pr-rebase.sh <project-dir> <head-branch>}

fail_mech() {
  echo "fm-pr-rebase: $1" >&2
  exit 1
}

git_path() {
  local p
  p=$(git -C "$REPO" rev-parse --git-path "$1")
  case "$p" in
    /*) printf '%s\n' "$p" ;;
    *) printf '%s/%s\n' "$REPO" "$p" ;;
  esac
}

ORIGIN_URL=$(git -C "$PROJECT_DIR" remote get-url origin 2>/dev/null) \
  || fail_mech "no origin remote in $PROJECT_DIR"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-pr-rebase.XXXXXX")
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

DEFAULT=$(git ls-remote --symref "$ORIGIN_URL" HEAD 2>/dev/null \
  | awk '$1 == "ref:" { sub(/^refs\/heads\//, "", $2); print $2; exit }')
[ -n "$DEFAULT" ] || fail_mech "cannot resolve default branch from origin $ORIGIN_URL"

REPO="$TMP/repo"
git clone --quiet --no-checkout "$PROJECT_DIR" "$REPO" 2>/dev/null \
  || fail_mech "scratch clone from $PROJECT_DIR failed"
git -C "$REPO" remote set-url origin "$ORIGIN_URL"
git -C "$REPO" fetch --quiet origin "$DEFAULT" "$HEAD_BRANCH" 2>/dev/null \
  || fail_mech "fetch of $DEFAULT and $HEAD_BRANCH from origin failed"

OLD_OID=$(git -C "$REPO" rev-parse --verify --quiet "refs/remotes/origin/$HEAD_BRANCH") \
  || fail_mech "origin/$HEAD_BRANCH missing after fetch"

# A rebase creates new commits, so the scratch clone needs a committer
# identity even on a machine with no global one; signing is forced off
# because a detached heal can never answer a signing prompt.
if ! git -C "$REPO" config user.email >/dev/null 2>&1; then
  git -C "$REPO" config user.email firstmate-autoheal@localhost
  git -C "$REPO" config user.name firstmate-autoheal
fi
git -C "$REPO" config commit.gpgsign false

git -C "$REPO" checkout --quiet -B "$HEAD_BRANCH" "refs/remotes/origin/$HEAD_BRANCH"
if ! git -C "$REPO" rebase --quiet "refs/remotes/origin/$DEFAULT" >/dev/null 2>&1; then
  rebase_merge=$(git_path rebase-merge)
  rebase_apply=$(git_path rebase-apply)
  if [ -d "$rebase_merge" ] || [ -d "$rebase_apply" ]; then
    FILES=$(git -C "$REPO" diff --name-only --diff-filter=U | tr '\n' ' ')
    git -C "$REPO" rebase --abort >/dev/null 2>&1 || true
    echo "conflict: ${FILES% }"
    exit 2
  fi
  fail_mech "rebase of $HEAD_BRANCH onto $DEFAULT failed for a non-conflict reason"
fi

NEW_OID=$(git -C "$REPO" rev-parse HEAD)
git -C "$REPO" push --quiet --force-with-lease="refs/heads/$HEAD_BRANCH:$OLD_OID" origin "$HEAD_BRANCH" 2>/dev/null \
  || fail_mech "push with lease of $HEAD_BRANCH refused (lease race, hook, or auth); remote untouched"

echo "rebased onto $DEFAULT: $OLD_OID -> $NEW_OID"
