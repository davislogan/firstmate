#!/usr/bin/env bash
# Record a PR-ready task: appends pr=<url> and GitHub's pr_head=<sha> to
# state/<id>.meta when available, then arms the watcher's merge poll by writing
# state/<id>.check.sh, which prints one line iff the PR is merged (the watcher's
# check contract: output = wake firstmate, silence = keep sleeping).
#
# On detecting its own merge, the generated check.sh also calls
# fm-pr-conflict-sweep.sh, which sweeps every other in-flight PR-based task
# for the same project (other state/*.meta with a pr= line and a matching
# project=), reports any sibling PR that has newly gone from mergeable to
# conflicted with main, and dispatches the detached auto-rebase heal - the
# moment a merge lands is exactly when a sibling still-open PR is most likely
# to develop a real conflict, and this closes the gap where that would
# otherwise only be caught reactively when a captain hits it live on GitHub.
# fm-pr-conflict-sweep.sh, fm-pr-autoheal.sh, and fm-pr-mergeable.sh own that
# logic; this script only arms the one line in the generated check.sh that
# calls out to it, so the sweep logic is never duplicated inline per task.
#
# Recording also runs fm-pr-sanitize.sh on the PR (unless FM_PR_SANITIZE=0),
# so no unicode dash survives in a PR title or body by the time the captain
# sees it; a sanitize failure only warns and never blocks arming the poll.
# Usage: fm-pr-check.sh <task-id> <pr-url>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
"$FM_ROOT/bin/fm-guard.sh" || true
ID=$1
URL=$2

META="$STATE/$ID.meta"
if [ -f "$META" ]; then
  WT=$(grep '^worktree=' "$META" | tail -1 | cut -d= -f2- || true)
  PR_HEAD=
  if [ -n "$WT" ] && [ -d "$WT" ]; then
    if command -v gh >/dev/null 2>&1; then
      if REMOTE_HEAD=$(cd "$WT" && gh pr view "$URL" --json headRefOid -q .headRefOid 2>/dev/null); then
        PR_HEAD=$REMOTE_HEAD
      fi
    fi
  fi
  if ! grep -qxF "pr=$URL" "$META"; then
    echo "pr=$URL" >> "$META"
  fi
  if [ -n "$PR_HEAD" ] && ! grep -qxF "pr_head=$PR_HEAD" "$META"; then
    echo "pr_head=$PR_HEAD" >> "$META"
  fi
fi

if [ "${FM_PR_SANITIZE:-1}" != "0" ]; then
  "$FM_ROOT/bin/fm-pr-sanitize.sh" "$URL" \
    || echo "fm-pr-check: warning: PR dash sanitize failed for $URL (continuing)" >&2
fi

cat > "$STATE/$ID.check.sh" <<EOF
state=\$(gh pr view "$URL" --json state -q .state 2>/dev/null)
if [ "\$state" = "MERGED" ]; then
  echo "merged"
  "$FM_ROOT/bin/fm-pr-conflict-sweep.sh" "$ID" "$STATE"
fi
EOF
echo "armed: state/$ID.check.sh polls $URL"
