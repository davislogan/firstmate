#!/usr/bin/env bash
# fm-pr-autoheal.sh - detached one-sibling heal orchestrator, dispatched by
# fm-pr-conflict-sweep.sh when a fresh merge makes a sibling in-flight PR
# conflict with the default branch. The sweep detaches it with setsid, so it
# runs OUTSIDE the watcher's FM_CHECK_TIMEOUT budget; its own runtime is
# bounded by FM_PR_AUTOHEAL_TIMEOUT (default 600s) around the rebase attempt.
#
# Owns every state write of the heal. The rebase mechanics live in
# fm-pr-rebase.sh (pure git, no state, never forces, never resolves a content
# conflict); this script translates its outcome onto the task's normal
# supervision channel:
#   - an appended status line on state/<id>.status, which the watcher
#     surfaces as an ordinary signal wake, and
#   - after a successful rebase, a fresh pr_head= line appended to
#     state/<id>.meta (meta readers use tail -1, so the stale recorded head
#     is superseded for fm-review-diff.sh and fm-teardown.sh).
#
# Status outcomes:
#   clean rebase     -> "working: PR <url> auto-rebased onto <default> ..."
#   content conflict -> "blocked: ... (conflicts: <files>); crew agent
#                       <alive|dead|unknown> - steer it to rebase, or
#                       respawn/escalate"
#   mechanical error -> "blocked: ... auto-rebase could not run (<reason>);
#                       manual rebase needed"
# The crew-liveness hint comes from fm_backend_agent_alive (bin/fm-backend.sh)
# so firstmate can steer a live crew or respawn/escalate a dead one in one
# step; the worktree recorded in meta survives either way.
#
# FM_PR_REBASE_BIN overrides the rebase helper (test seam, like
# FM_CREW_STATE_BIN); FM_PR_AUTOHEAL_TIMEOUT bounds the attempt in seconds.
# Usage: fm-pr-autoheal.sh <task-id> <state-dir>
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ID=${1:?usage: fm-pr-autoheal.sh <task-id> <state-dir>}
STATE_DIR=${2:?usage: fm-pr-autoheal.sh <task-id> <state-dir>}

META="$STATE_DIR/$ID.meta"
STATUS_FILE="$STATE_DIR/$ID.status"
REBASE_BIN=${FM_PR_REBASE_BIN:-$SCRIPT_DIR/fm-pr-rebase.sh}
TIMEOUT_SECS=${FM_PR_AUTOHEAL_TIMEOUT:-600}

status() { printf '%s\n' "$1" >> "$STATUS_FILE"; }

[ -f "$META" ] || { echo "fm-pr-autoheal: no meta for task $ID at $META" >&2; exit 1; }
PROJECT=$(grep '^project=' "$META" | tail -1 | cut -d= -f2- || true)
PR_URL=$(grep '^pr=' "$META" | tail -1 | cut -d= -f2- || true)
if [ -z "$PROJECT" ] || [ -z "$PR_URL" ]; then
  echo "fm-pr-autoheal: meta for $ID lacks project= or pr=" >&2
  exit 1
fi

crew_liveness() {
  local target backend
  # shellcheck source=bin/fm-backend.sh disable=SC1091
  . "$SCRIPT_DIR/fm-backend.sh" 2>/dev/null || { printf 'unknown'; return 0; }
  backend=$(fm_backend_of_meta "$META")
  target=$(fm_backend_target_of_meta "$META")
  [ -n "$target" ] || { printf 'unknown'; return 0; }
  fm_backend_agent_alive "$backend" "$target" 2>/dev/null || printf 'unknown'
}

HEAD_BRANCH=$(gh pr view "$PR_URL" --json headRefName -q .headRefName 2>/dev/null || true)
if [ -z "$HEAD_BRANCH" ]; then
  status "blocked: PR $PR_URL conflicts with the default branch after a sibling merge; auto-rebase could not run (could not resolve the PR head branch); manual rebase needed"
  exit 1
fi

ERR_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-pr-autoheal.XXXXXX")
trap 'rm -f "$ERR_FILE"' EXIT

run_rebase() {
  if command -v timeout >/dev/null 2>&1; then
    timeout "$TIMEOUT_SECS" "$REBASE_BIN" "$PROJECT" "$HEAD_BRANCH"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$TIMEOUT_SECS" "$REBASE_BIN" "$PROJECT" "$HEAD_BRANCH"
  else
    "$REBASE_BIN" "$PROJECT" "$HEAD_BRANCH"
  fi
}

set +e
OUT=$(run_rebase 2>"$ERR_FILE")
RC=$?
# Keep the raw attempt visible in the sweep-provided autoheal log.
[ -n "$OUT" ] && printf '%s\n' "$OUT"
cat "$ERR_FILE" >&2 || true

case "$RC" in
  0)
    DEFAULT=$(printf '%s' "$OUT" | sed -n 's/^rebased onto \([^:]*\):.*/\1/p')
    NEW_OID=${OUT##*-> }
    case "$NEW_OID" in
      *[!0-9a-f]*|"") NEW_OID= ;;
    esac
    if [ -n "$NEW_OID" ] && ! grep -qxF "pr_head=$NEW_OID" "$META"; then
      echo "pr_head=$NEW_OID" >> "$META"
    fi
    status "working: PR $PR_URL auto-rebased onto ${DEFAULT:-the default branch} after a sibling merge landed; checks re-running - verify they return green"
    ;;
  2)
    FILES=${OUT#conflict: }
    LIVENESS=$(crew_liveness)
    status "blocked: PR $PR_URL conflicts with the default branch after a sibling merge; auto-rebase aborted (conflicts: ${FILES:-unknown}); crew agent ${LIVENESS:-unknown} - steer it to rebase, or respawn/escalate"
    exit 2
    ;;
  124)
    status "blocked: PR $PR_URL conflicts with the default branch after a sibling merge; auto-rebase could not run (timed out after ${TIMEOUT_SECS}s); manual rebase needed"
    exit 1
    ;;
  *)
    REASON=$(tail -1 "$ERR_FILE" 2>/dev/null || true)
    status "blocked: PR $PR_URL conflicts with the default branch after a sibling merge; auto-rebase could not run (${REASON:-rebase helper failed with code $RC}); manual rebase needed"
    exit 1
    ;;
esac
