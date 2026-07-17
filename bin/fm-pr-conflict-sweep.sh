#!/usr/bin/env bash
# Single sweep point for "did this task's PR merge just conflict a sibling
# PR". Called from state/<id>.check.sh (see fm-pr-check.sh) the instant that
# task's own PR is detected merged: at that moment every other still-open
# PR-based task against the same project may have just gone from mergeable
# to conflicted with the newly updated base branch, and this is the one place
# that walks state/*.meta to find them.
#
# A sibling is any other state/*.meta with a project= matching this task's
# own project= and a pr= line recorded (an in-flight PR-based ship task).
# Each sibling's live mergeable state comes from fm-pr-mergeable.sh, the one
# place that owns the actual `gh api ... mergeable_state` call.
#
# Detect + dispatch only. For each sibling PR now "dirty" (GitHub's canonical
# merge-conflict signal) this prints one wake line, and - unless
# FM_PR_AUTOREBASE=0 - detaches fm-pr-autoheal.sh (setsid, with a perl
# new-session re-exec fallback where setsid is absent, logging to
# state/<id>.autoheal.log) to attempt the clean rebase outside the watcher's
# FM_CHECK_TIMEOUT budget; the heal's own outcome comes back later as a
# status-line signal wake, per fm-pr-autoheal.sh's contract. A per-sibling
# marker at state/<id>.autoheal records the head OID last attempted, so a
# merged task's check re-firing before its teardown never double-heals the
# same incident; a changed head OID is a new incident and heals again.
# When the head OID cannot be resolved, the sweep stays detect-only for that
# sibling. Prints nothing when every sibling is still clean or its state
# could not be determined, matching the watcher's check.sh contract
# (silence = keep sleeping, output = wake).
#
# FM_PR_AUTOHEAL_BIN overrides the dispatched heal (test seam, like
# FM_CREW_STATE_BIN).
# Usage: fm-pr-conflict-sweep.sh <task-id> <state-dir>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TASK_ID=${1:?usage: fm-pr-conflict-sweep.sh <task-id> <state-dir>}
STATE_DIR=${2:?usage: fm-pr-conflict-sweep.sh <task-id> <state-dir>}

# shellcheck source=bin/fm-pr-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-pr-lib.sh"

AUTOHEAL_BIN=${FM_PR_AUTOHEAL_BIN:-$SCRIPT_DIR/fm-pr-autoheal.sh}

OWN_META="$STATE_DIR/$TASK_ID.meta"
[ -f "$OWN_META" ] || exit 0

OWN_PROJECT=$(grep '^project=' "$OWN_META" | tail -1 | cut -d= -f2- || true)
[ -n "$OWN_PROJECT" ] || exit 0

dispatch_autoheal() {
  local sib=$1 log="$STATE_DIR/$1.autoheal.log"
  if command -v setsid >/dev/null 2>&1; then
    setsid "$AUTOHEAL_BIN" "$sib" "$STATE_DIR" </dev/null >>"$log" 2>&1 &
  elif command -v perl >/dev/null 2>&1; then
    # No setsid (e.g. stock macOS): re-exec into a fresh session via perl, so a
    # sweep overrunning FM_CHECK_TIMEOUT cannot group-kill an in-flight heal.
    # Bare nohup only ignores SIGHUP and would stay in the killable group; perl
    # is the same dependency the watcher's own timeout fallback relies on. Fork
    # first (as setsid(1) itself does) so the child is never a process-group
    # leader and POSIX::setsid always succeeds regardless of job-control state.
    # shellcheck disable=SC2016  # single quotes deliberate: perl expands @ARGV.
    perl -MPOSIX -e 'my $pid = fork; exit(0) if $pid; POSIX::setsid(); exec @ARGV or die "exec failed: $!"' \
      -- "$AUTOHEAL_BIN" "$sib" "$STATE_DIR" </dev/null >>"$log" 2>&1 &
  else
    # Last resort with neither setsid nor perl: nohup cannot escape the process
    # group, so an overrunning sweep may still reap this heal.
    nohup "$AUTOHEAL_BIN" "$sib" "$STATE_DIR" </dev/null >>"$log" 2>&1 &
  fi
}

for m in "$STATE_DIR"/*.meta; do
  [ -e "$m" ] || continue
  sib_id=$(basename "$m" .meta)
  [ "$sib_id" != "$TASK_ID" ] || continue

  sib_project=$(grep '^project=' "$m" | tail -1 | cut -d= -f2- || true)
  [ "$sib_project" = "$OWN_PROJECT" ] || continue

  sib_pr=$(grep '^pr=' "$m" | tail -1 | cut -d= -f2- || true)
  [ -n "$sib_pr" ] || continue

  fm_pr_parse_url "$sib_pr" 2>/dev/null || continue

  state=$("$SCRIPT_DIR/fm-pr-mergeable.sh" "$OWN_PROJECT" "$PR_NUMBER" 2>/dev/null) || continue
  [ "$state" = "dirty" ] || continue

  base_line="$sib_id PR $sib_pr now has a merge conflict with main"
  if [ "${FM_PR_AUTOREBASE:-1}" = "0" ]; then
    echo "$base_line"
    continue
  fi

  head_oid=$(gh pr view "$sib_pr" --json headRefOid -q .headRefOid 2>/dev/null || true)
  if [ -z "$head_oid" ]; then
    echo "$base_line"
    continue
  fi

  marker="$STATE_DIR/$sib_id.autoheal"
  if [ -f "$marker" ] && [ "$(cat "$marker" 2>/dev/null)" = "$head_oid" ]; then
    echo "$sib_id PR $sib_pr still has a merge conflict with main; auto-rebase already attempted - see state/$sib_id.status"
    continue
  fi

  printf '%s\n' "$head_oid" > "$marker"
  echo "$base_line; auto-rebase dispatched - outcome follows on the task's status"
  dispatch_autoheal "$sib_id"
done
