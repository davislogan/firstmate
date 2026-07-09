#!/usr/bin/env bash
# Single sweep point for "did this task's PR merge just conflict a sibling
# PR". Called from state/<id>.check.sh (see fm-pr-check.sh) the instant that
# task's own PR is detected merged: at that moment every other still-open
# PR-based task against the same project may have just gone from mergeable
# to conflicted with the newly updated base branch, and this is the one place
# that walks state/*.meta to find and report them.
#
# A sibling is any other state/*.meta with a project= matching this task's
# own project= and a pr= line recorded (an in-flight PR-based ship task).
# Each sibling's live mergeable state comes from fm-pr-mergeable.sh, the one
# place that owns the actual `gh api ... mergeable_state` call.
#
# Prints one line per sibling task whose PR is now "dirty" (GitHub's
# canonical merge-conflict signal); prints nothing when every sibling is
# still clean or its state could not be determined, matching the watcher's
# check.sh contract (silence = keep sleeping, output = wake).
#
# Usage: fm-pr-conflict-sweep.sh <task-id> <state-dir>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TASK_ID=${1:?usage: fm-pr-conflict-sweep.sh <task-id> <state-dir>}
STATE_DIR=${2:?usage: fm-pr-conflict-sweep.sh <task-id> <state-dir>}

OWN_META="$STATE_DIR/$TASK_ID.meta"
[ -f "$OWN_META" ] || exit 0

OWN_PROJECT=$(grep '^project=' "$OWN_META" | tail -1 | cut -d= -f2- || true)
[ -n "$OWN_PROJECT" ] || exit 0

for m in "$STATE_DIR"/*.meta; do
  [ -e "$m" ] || continue
  sib_id=$(basename "$m" .meta)
  [ "$sib_id" != "$TASK_ID" ] || continue

  sib_project=$(grep '^project=' "$m" | tail -1 | cut -d= -f2- || true)
  [ "$sib_project" = "$OWN_PROJECT" ] || continue

  sib_pr=$(grep '^pr=' "$m" | tail -1 | cut -d= -f2- || true)
  [ -n "$sib_pr" ] || continue

  num=$(printf '%s' "$sib_pr" | sed -n -E 's#.*/pull/([0-9]+)/?$#\1#p')
  [ -n "$num" ] || continue

  state=$("$SCRIPT_DIR/fm-pr-mergeable.sh" "$OWN_PROJECT" "$num" 2>/dev/null) || continue
  if [ "$state" = "dirty" ]; then
    echo "$sib_id PR $sib_pr now has a merge conflict with main"
  fi
done
