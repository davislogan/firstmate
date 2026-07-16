#!/usr/bin/env bash
# tests/fm-pr-conflict-sweep.test.sh - proactive sibling-PR-conflict detection:
# when one task's PR merges, every other in-flight PR-based task for the same
# project gets its live mergeable state checked, and a sibling that has newly
# gone from mergeable to conflicted with main is surfaced as an actionable
# watcher wake instead of only being caught reactively later.
#
# Matrix:
#   fm-pr-mergeable.sh (the single owner of "check a PR's mergeable state via
#   gh api", resolving owner/repo from a project clone's origin remote):
#     (a) resolves an https:// origin remote and prints mergeable_state
#     (b) resolves a git@ SSH origin remote and prints mergeable_state
#     (c) fails clearly when the project has no origin remote
#     (d) fails clearly when the origin remote cannot be parsed to owner/repo
#   fm-pr-conflict-sweep.sh (the sibling sweep driven by that helper):
#     (e) reports a sibling PR whose mergeable_state is now dirty
#     (f) stays silent for a sibling PR that is still clean
#     (g) stays silent for a sibling PR that is merely unstable, not dirty
#     (h) never reports and never queries a sibling in a different project
#     (i) skips a sibling task with no pr= line (not a PR-based task)
#     (j) skips itself and is a silent no-op when it is the only in-flight task
#     (k) is a silent no-op when the task id has no meta file at all
#   fm-pr-check.sh + the watcher (end-to-end wiring):
#     (l) the generated check.sh only runs the sweep after detecting its own
#         merge, staying fully silent (no sweep, no gh api calls) while open
#     (m) once merged, running the generated check.sh directly reports both
#         its own "merged" line and a newly conflicted sibling's line
#     (n) the real watcher's *.check.sh sweep surfaces both as one wake
#   auto-heal dispatch (FM_PR_AUTOHEAL_BIN stubbed; the heal itself is covered
#   by tests/fm-pr-autoheal.test.sh and tests/fm-pr-rebase.test.sh):
#     (o) a dirty sibling dispatches the detached heal exactly once per head
#         OID (state/<id>.autoheal marker), re-reports without re-dispatching
#         while the OID is unchanged, and re-heals on a new head OID
#     (p) FM_PR_AUTOREBASE=0 keeps the sweep detect-only: today's exact line,
#         no marker, no dispatch
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
fm_git_identity fmtest fmtest@example.invalid

MERGEABLE="$ROOT/bin/fm-pr-mergeable.sh"
SWEEP="$ROOT/bin/fm-pr-conflict-sweep.sh"
PR_CHECK="$ROOT/bin/fm-pr-check.sh"
WATCH="$ROOT/bin/fm-watch.sh"

TMP_ROOT=$(fm_test_tmproot fm-pr-conflict-sweep-tests)

# make_project <dir> <origin-url>: a bare-minimum git repo with the given
# origin remote. fm-pr-mergeable.sh only ever reads git config for this repo,
# never fetches or pushes, so no commit or real remote is needed.
make_project() {
  local dir=$1 origin=$2
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" remote add origin "$origin"
}

# add_gh_mock <fakebin>: a gh mock driven by env vars, read fresh on each call:
#   FM_TEST_PR_STATE      answer for `gh pr view <url> --json state -q .state`
#   FM_TEST_MERGEABLE_DIR dir of files named <pr-number>, each holding the
#                         mergeable_state to answer for
#                         `gh api repos/.../pulls/<n> --jq .mergeable_state`;
#                         a missing file answers "clean"
#   FM_TEST_GH_LOG        every invocation's args, one per line, when set
add_gh_mock() {
  local fakebin=$1
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
[ -n "${FM_TEST_GH_LOG:-}" ] && printf '%s\n' "$*" >> "$FM_TEST_GH_LOG"
case "${1:-} ${2:-}" in
  "pr view")
    case " $* " in
      *"--json state"*) printf '%s\n' "${FM_TEST_PR_STATE:-OPEN}" ;;
      *headRefOid*) printf '%s\n' "${FM_TEST_PR_HEAD:-}" ;;
    esac
    exit 0 ;;
esac
if [ "${1:-}" = "api" ]; then
  path="${2:-}"
  num="${path##*/}"
  if [ -n "${FM_TEST_MERGEABLE_DIR:-}" ] && [ -f "$FM_TEST_MERGEABLE_DIR/$num" ]; then
    cat "$FM_TEST_MERGEABLE_DIR/$num"
  else
    printf 'clean\n'
  fi
  exit 0
fi
exit 1
SH
  chmod +x "$fakebin/gh"
}

# --- fm-pr-mergeable.sh ------------------------------------------------------

test_mergeable_resolves_https_origin() {
  local case_dir project fakebin mdir out
  case_dir="$TMP_ROOT/mergeable-https"
  project="$case_dir/project"
  fakebin="$case_dir/fakebin"
  mdir="$case_dir/mergeable"
  mkdir -p "$fakebin" "$mdir"
  make_project "$project" "https://github.com/example/repo.git"
  add_gh_mock "$fakebin"
  printf 'dirty\n' > "$mdir/71"

  out=$(FM_TEST_MERGEABLE_DIR="$mdir" PATH="$fakebin:$PATH" "$MERGEABLE" "$project" 71) \
    || fail "mergeable-https: fm-pr-mergeable.sh failed"
  [ "$out" = "dirty" ] || fail "mergeable-https: expected dirty, got '$out'"
  pass "fm-pr-mergeable.sh resolves an https:// origin remote and reports mergeable_state"
}

test_mergeable_resolves_ssh_origin() {
  local case_dir project fakebin mdir out
  case_dir="$TMP_ROOT/mergeable-ssh"
  project="$case_dir/project"
  fakebin="$case_dir/fakebin"
  mdir="$case_dir/mergeable"
  mkdir -p "$fakebin" "$mdir"
  make_project "$project" "git@github.com:example/repo.git"
  add_gh_mock "$fakebin"
  printf 'clean\n' > "$mdir/9"

  out=$(FM_TEST_MERGEABLE_DIR="$mdir" PATH="$fakebin:$PATH" "$MERGEABLE" "$project" 9) \
    || fail "mergeable-ssh: fm-pr-mergeable.sh failed"
  [ "$out" = "clean" ] || fail "mergeable-ssh: expected clean, got '$out'"
  pass "fm-pr-mergeable.sh resolves a git@ SSH origin remote and reports mergeable_state"
}

test_mergeable_fails_without_origin() {
  local case_dir project fakebin rc
  case_dir="$TMP_ROOT/mergeable-no-origin"
  project="$case_dir/project"
  fakebin="$case_dir/fakebin"
  mkdir -p "$project" "$fakebin"
  git -C "$project" init -q
  add_gh_mock "$fakebin"

  set +e
  PATH="$fakebin:$PATH" "$MERGEABLE" "$project" 1 > "$case_dir/out" 2> "$case_dir/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "mergeable-no-origin: fm-pr-mergeable.sh should refuse"
  assert_grep 'no origin remote' "$case_dir/err" "mergeable-no-origin: refusal did not explain the missing origin"
  pass "fm-pr-mergeable.sh fails clearly when the project has no origin remote"
}

test_mergeable_fails_on_unparseable_origin() {
  local case_dir project fakebin rc
  case_dir="$TMP_ROOT/mergeable-bad-origin"
  project="$case_dir/project"
  fakebin="$case_dir/fakebin"
  mkdir -p "$fakebin"
  make_project "$project" "not-a-url"
  add_gh_mock "$fakebin"

  set +e
  PATH="$fakebin:$PATH" "$MERGEABLE" "$project" 1 > "$case_dir/out" 2> "$case_dir/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "mergeable-bad-origin: fm-pr-mergeable.sh should refuse"
  assert_grep 'could not parse owner/repo' "$case_dir/err" "mergeable-bad-origin: refusal did not explain the unparseable origin"
  pass "fm-pr-mergeable.sh fails clearly when the origin remote cannot be parsed to owner/repo"
}

# --- fm-pr-conflict-sweep.sh --------------------------------------------------

# make_sweep_case <name>: a state dir plus a project git repo with an
# https://github.com/example/repo.git origin. Echoes "state project".
make_sweep_case() {
  local name=$1 dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/state" "$dir/fakebin"
  make_project "$dir/project" "https://github.com/example/repo.git"
  add_gh_mock "$dir/fakebin"
  printf '%s %s %s\n' "$dir/state" "$dir/project" "$dir/fakebin"
}

test_sweep_reports_dirty_sibling() {
  local vals state project fakebin mdir out
  vals=$(make_sweep_case sweep-dirty)
  state=$(echo "$vals" | cut -d' ' -f1)
  project=$(echo "$vals" | cut -d' ' -f2)
  fakebin=$(echo "$vals" | cut -d' ' -f3)
  mdir="$TMP_ROOT/sweep-dirty/mergeable"
  mkdir -p "$mdir"
  printf 'dirty\n' > "$mdir/71"

  fm_write_meta "$state/own.meta" "project=$project"
  fm_write_meta "$state/sib.meta" "project=$project" "pr=https://github.com/example/repo/pull/71"

  out=$(FM_TEST_MERGEABLE_DIR="$mdir" PATH="$fakebin:$PATH" "$SWEEP" own "$state") \
    || fail "sweep-dirty: fm-pr-conflict-sweep.sh failed"
  assert_contains "$out" 'sib PR https://github.com/example/repo/pull/71 now has a merge conflict with main' \
    "sweep-dirty: dirty sibling was not reported"
  pass "fm-pr-conflict-sweep.sh reports a sibling PR whose mergeable_state is now dirty"
}

test_sweep_silent_when_sibling_clean() {
  local vals state project fakebin mdir out
  vals=$(make_sweep_case sweep-clean)
  state=$(echo "$vals" | cut -d' ' -f1)
  project=$(echo "$vals" | cut -d' ' -f2)
  fakebin=$(echo "$vals" | cut -d' ' -f3)
  mdir="$TMP_ROOT/sweep-clean/mergeable"
  mkdir -p "$mdir"
  printf 'clean\n' > "$mdir/71"

  fm_write_meta "$state/own.meta" "project=$project"
  fm_write_meta "$state/sib.meta" "project=$project" "pr=https://github.com/example/repo/pull/71"

  out=$(FM_TEST_MERGEABLE_DIR="$mdir" PATH="$fakebin:$PATH" "$SWEEP" own "$state") \
    || fail "sweep-clean: fm-pr-conflict-sweep.sh failed"
  [ -z "$out" ] || fail "sweep-clean: a clean sibling should produce no output (got: $out)"
  pass "fm-pr-conflict-sweep.sh stays silent for a sibling PR that is still clean"
}

test_sweep_silent_when_sibling_unstable() {
  local vals state project fakebin mdir out
  vals=$(make_sweep_case sweep-unstable)
  state=$(echo "$vals" | cut -d' ' -f1)
  project=$(echo "$vals" | cut -d' ' -f2)
  fakebin=$(echo "$vals" | cut -d' ' -f3)
  mdir="$TMP_ROOT/sweep-unstable/mergeable"
  mkdir -p "$mdir"
  printf 'unstable\n' > "$mdir/71"

  fm_write_meta "$state/own.meta" "project=$project"
  fm_write_meta "$state/sib.meta" "project=$project" "pr=https://github.com/example/repo/pull/71"

  out=$(FM_TEST_MERGEABLE_DIR="$mdir" PATH="$fakebin:$PATH" "$SWEEP" own "$state") \
    || fail "sweep-unstable: fm-pr-conflict-sweep.sh failed"
  [ -z "$out" ] || fail "sweep-unstable: only dirty is a conflict, unstable should produce no output (got: $out)"
  pass "fm-pr-conflict-sweep.sh stays silent for a sibling PR that is merely unstable, not dirty"
}

test_sweep_ignores_different_project() {
  local dir state fakebin mdir out log
  dir="$TMP_ROOT/sweep-other-project"
  mkdir -p "$dir/state" "$dir/fakebin"
  make_project "$dir/project-a" "https://github.com/example/repo-a.git"
  make_project "$dir/project-b" "https://github.com/example/repo-b.git"
  add_gh_mock "$dir/fakebin"
  mdir="$dir/mergeable"
  mkdir -p "$mdir"
  printf 'dirty\n' > "$mdir/71"
  state="$dir/state"; fakebin="$dir/fakebin"

  fm_write_meta "$state/own.meta" "project=$dir/project-a"
  fm_write_meta "$state/sib.meta" "project=$dir/project-b" "pr=https://github.com/example/repo-b/pull/71"

  log="$dir/gh.log"
  : > "$log"
  out=$(FM_TEST_GH_LOG="$log" FM_TEST_MERGEABLE_DIR="$mdir" PATH="$fakebin:$PATH" "$SWEEP" own "$state") \
    || fail "sweep-other-project: fm-pr-conflict-sweep.sh failed"
  [ -z "$out" ] || fail "sweep-other-project: a sibling in a different project must never be reported (got: $out)"
  assert_no_grep 'pulls/71' "$log" "sweep-other-project: a sibling in a different project must never even be queried"
  pass "fm-pr-conflict-sweep.sh never reports or queries a sibling in a different project"
}

test_sweep_skips_non_pr_task() {
  local vals state project fakebin out
  vals=$(make_sweep_case sweep-non-pr)
  state=$(echo "$vals" | cut -d' ' -f1)
  project=$(echo "$vals" | cut -d' ' -f2)
  fakebin=$(echo "$vals" | cut -d' ' -f3)

  fm_write_meta "$state/own.meta" "project=$project"
  fm_write_meta "$state/sib.meta" "project=$project" "kind=scout"

  out=$(PATH="$fakebin:$PATH" "$SWEEP" own "$state") || fail "sweep-non-pr: fm-pr-conflict-sweep.sh failed"
  [ -z "$out" ] || fail "sweep-non-pr: a sibling with no pr= line must be skipped (got: $out)"
  pass "fm-pr-conflict-sweep.sh skips a sibling task with no pr= line"
}

test_sweep_skips_self_and_is_noop_alone() {
  local vals state project fakebin out
  vals=$(make_sweep_case sweep-alone)
  state=$(echo "$vals" | cut -d' ' -f1)
  project=$(echo "$vals" | cut -d' ' -f2)
  fakebin=$(echo "$vals" | cut -d' ' -f3)

  fm_write_meta "$state/own.meta" "project=$project" "pr=https://github.com/example/repo/pull/9"

  out=$(PATH="$fakebin:$PATH" "$SWEEP" own "$state") || fail "sweep-alone: fm-pr-conflict-sweep.sh failed"
  [ -z "$out" ] || fail "sweep-alone: sweep must not report its own task (got: $out)"
  pass "fm-pr-conflict-sweep.sh skips itself and is a silent no-op when it is the only in-flight task"
}

test_sweep_noop_without_own_meta() {
  local dir state rc out
  dir="$TMP_ROOT/sweep-no-own-meta"
  mkdir -p "$dir/state"
  state="$dir/state"

  set +e
  out=$("$SWEEP" missing "$state" 2>"$dir/err")
  rc=$?
  set -e
  expect_code 0 "$rc" "sweep-no-own-meta: fm-pr-conflict-sweep.sh should exit 0"
  [ -z "$out" ] || fail "sweep-no-own-meta: expected no output, got: $out"
  pass "fm-pr-conflict-sweep.sh is a silent no-op when the task id has no meta file at all"
}

# --- auto-heal dispatch -------------------------------------------------------

# add_autoheal_stub <fakebin>: a recording FM_PR_AUTOHEAL_BIN stand-in; each
# invocation appends its args to $FM_TEST_AUTOHEAL_LOG.
add_autoheal_stub() {
  local fakebin=$1
  cat > "$fakebin/autoheal-stub" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_AUTOHEAL_LOG"
exit 0
SH
  chmod +x "$fakebin/autoheal-stub"
}

# wait_for_log_lines <file> <n>: the sweep detaches the heal, so give the
# stub a moment to land its record before asserting.
wait_for_log_lines() {
  local file=$1 n=$2 tries=50
  while [ "$tries" -gt 0 ]; do
    if [ -f "$file" ] && [ "$(grep -c '' "$file")" -ge "$n" ]; then
      return 0
    fi
    tries=$((tries - 1))
    sleep 0.1
  done
  return 1
}

test_sweep_dispatches_autoheal_once_per_head_oid() {
  local vals state project fakebin mdir log out
  vals=$(make_sweep_case sweep-autoheal)
  state=$(echo "$vals" | cut -d' ' -f1)
  project=$(echo "$vals" | cut -d' ' -f2)
  fakebin=$(echo "$vals" | cut -d' ' -f3)
  add_autoheal_stub "$fakebin"
  mdir="$TMP_ROOT/sweep-autoheal/mergeable"
  mkdir -p "$mdir"
  printf 'dirty\n' > "$mdir/71"
  log="$TMP_ROOT/sweep-autoheal/heal.log"

  fm_write_meta "$state/own.meta" "project=$project"
  fm_write_meta "$state/sib.meta" "project=$project" "pr=https://github.com/example/repo/pull/71"

  out=$(FM_TEST_PR_HEAD=abc123 FM_TEST_AUTOHEAL_LOG="$log" FM_TEST_MERGEABLE_DIR="$mdir" \
    FM_PR_AUTOHEAL_BIN="$fakebin/autoheal-stub" PATH="$fakebin:$PATH" "$SWEEP" own "$state") \
    || fail "sweep-autoheal: sweep failed on dispatch"
  assert_contains "$out" 'auto-rebase dispatched' "sweep-autoheal: dispatch was not reported"
  wait_for_log_lines "$log" 1 || fail "sweep-autoheal: detached heal was never invoked"
  assert_grep "sib $state" "$log" "sweep-autoheal: heal did not get the sibling id and state dir"
  [ "$(cat "$state/sib.autoheal")" = "abc123" ] || fail "sweep-autoheal: marker does not record the head OID"

  out=$(FM_TEST_PR_HEAD=abc123 FM_TEST_AUTOHEAL_LOG="$log" FM_TEST_MERGEABLE_DIR="$mdir" \
    FM_PR_AUTOHEAL_BIN="$fakebin/autoheal-stub" PATH="$fakebin:$PATH" "$SWEEP" own "$state") \
    || fail "sweep-autoheal: sweep failed on re-fire"
  assert_contains "$out" 'auto-rebase already attempted' "sweep-autoheal: re-fire did not point at the prior attempt"
  sleep 0.3
  [ "$(grep -c '' "$log")" -eq 1 ] || fail "sweep-autoheal: an unchanged head OID must not re-dispatch"

  out=$(FM_TEST_PR_HEAD=def456 FM_TEST_AUTOHEAL_LOG="$log" FM_TEST_MERGEABLE_DIR="$mdir" \
    FM_PR_AUTOHEAL_BIN="$fakebin/autoheal-stub" PATH="$fakebin:$PATH" "$SWEEP" own "$state") \
    || fail "sweep-autoheal: sweep failed on new head OID"
  assert_contains "$out" 'auto-rebase dispatched' "sweep-autoheal: a new head OID must dispatch again"
  wait_for_log_lines "$log" 2 || fail "sweep-autoheal: new head OID never re-dispatched"
  [ "$(cat "$state/sib.autoheal")" = "def456" ] || fail "sweep-autoheal: marker was not advanced to the new head OID"
  pass "fm-pr-conflict-sweep.sh dispatches the detached heal exactly once per head OID"
}

test_sweep_optout_stays_detect_only() {
  local vals state project fakebin mdir out
  vals=$(make_sweep_case sweep-optout)
  state=$(echo "$vals" | cut -d' ' -f1)
  project=$(echo "$vals" | cut -d' ' -f2)
  fakebin=$(echo "$vals" | cut -d' ' -f3)
  add_autoheal_stub "$fakebin"
  mdir="$TMP_ROOT/sweep-optout/mergeable"
  mkdir -p "$mdir"
  printf 'dirty\n' > "$mdir/71"

  fm_write_meta "$state/own.meta" "project=$project"
  fm_write_meta "$state/sib.meta" "project=$project" "pr=https://github.com/example/repo/pull/71"

  out=$(FM_PR_AUTOREBASE=0 FM_TEST_PR_HEAD=abc123 FM_TEST_AUTOHEAL_LOG="$TMP_ROOT/sweep-optout/heal.log" \
    FM_TEST_MERGEABLE_DIR="$mdir" FM_PR_AUTOHEAL_BIN="$fakebin/autoheal-stub" PATH="$fakebin:$PATH" \
    "$SWEEP" own "$state") \
    || fail "sweep-optout: sweep failed with auto-heal off"
  [ "$out" = "sib PR https://github.com/example/repo/pull/71 now has a merge conflict with main" ] \
    || fail "sweep-optout: opt-out must print exactly the detect-only line (got: $out)"
  [ ! -e "$state/sib.autoheal" ] || fail "sweep-optout: opt-out must not write a marker"
  [ ! -e "$TMP_ROOT/sweep-optout/heal.log" ] || fail "sweep-optout: opt-out must not dispatch"
  pass "FM_PR_AUTOREBASE=0 keeps the sweep detect-only"
}

# --- fm-pr-check.sh + watcher wiring -----------------------------------------

test_generated_check_silent_while_pr_open() {
  local dir state project fakebin mdir out log
  dir="$TMP_ROOT/wiring-open"
  mkdir -p "$dir/state" "$dir/fakebin"
  make_project "$dir/project" "https://github.com/example/repo.git"
  add_gh_mock "$dir/fakebin"
  state="$dir/state"; project="$dir/project"; fakebin="$dir/fakebin"
  mdir="$dir/mergeable"
  mkdir -p "$mdir"
  printf 'dirty\n' > "$mdir/71"

  fm_write_meta "$state/task-a.meta" "window=fm-task-a" "project=$project" "kind=ship" "mode=no-mistakes"
  fm_write_meta "$state/task-b.meta" "window=fm-task-b" "project=$project" "kind=ship" "mode=no-mistakes" \
    "pr=https://github.com/example/repo/pull/71"

  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" PATH="$fakebin:$PATH" \
    "$PR_CHECK" task-a "https://github.com/example/repo/pull/70" >/dev/null \
    || fail "wiring-open: fm-pr-check.sh failed to arm"

  log="$dir/gh.log"
  : > "$log"
  out=$(FM_TEST_PR_STATE=OPEN FM_TEST_MERGEABLE_DIR="$mdir" FM_TEST_GH_LOG="$log" \
    PATH="$fakebin:$PATH" bash "$state/task-a.check.sh")
  [ -z "$out" ] || fail "wiring-open: an unmerged own PR must produce no output (got: $out)"
  assert_no_grep 'pulls/71' "$log" "wiring-open: the sweep must not run at all while the own PR is still open"
  pass "the generated check.sh only runs the sweep after detecting its own merge, staying silent while open"
}

test_generated_check_reports_merge_and_sibling_conflict() {
  local dir state project fakebin mdir out
  dir="$TMP_ROOT/wiring-merged"
  mkdir -p "$dir/state" "$dir/fakebin"
  make_project "$dir/project" "https://github.com/example/repo.git"
  add_gh_mock "$dir/fakebin"
  state="$dir/state"; project="$dir/project"; fakebin="$dir/fakebin"
  mdir="$dir/mergeable"
  mkdir -p "$mdir"
  printf 'dirty\n' > "$mdir/71"

  fm_write_meta "$state/task-a.meta" "window=fm-task-a" "project=$project" "kind=ship" "mode=no-mistakes"
  fm_write_meta "$state/task-b.meta" "window=fm-task-b" "project=$project" "kind=ship" "mode=no-mistakes" \
    "pr=https://github.com/example/repo/pull/71"

  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" PATH="$fakebin:$PATH" \
    "$PR_CHECK" task-a "https://github.com/example/repo/pull/70" >/dev/null \
    || fail "wiring-merged: fm-pr-check.sh failed to arm"

  out=$(FM_TEST_PR_STATE=MERGED FM_TEST_MERGEABLE_DIR="$mdir" PATH="$fakebin:$PATH" bash "$state/task-a.check.sh")
  assert_contains "$out" "merged" "wiring-merged: own merge was not reported"
  assert_contains "$out" "task-b PR https://github.com/example/repo/pull/71 now has a merge conflict with main" \
    "wiring-merged: newly conflicted sibling was not reported"
  pass "once merged, the generated check.sh reports both its own merge and a newly conflicted sibling"
}

test_watcher_surfaces_merge_and_conflict_as_one_wake() {
  local dir state project fakebin mdir out
  dir=$(make_case watch-wiring)
  state="$dir/state"
  fakebin="$dir/fakebin"
  add_gh_mock "$fakebin"
  project="$dir/project"
  make_project "$project" "https://github.com/example/repo.git"
  mdir="$dir/mergeable"
  mkdir -p "$mdir"
  printf 'dirty\n' > "$mdir/71"

  fm_write_meta "$state/task-a.meta" "window=fm-task-a" "project=$project" "kind=ship" "mode=no-mistakes"
  fm_write_meta "$state/task-b.meta" "window=fm-task-b" "project=$project" "kind=ship" "mode=no-mistakes" \
    "pr=https://github.com/example/repo/pull/71"

  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" PATH="$fakebin:$PATH" \
    "$PR_CHECK" task-a "https://github.com/example/repo/pull/70" >/dev/null \
    || fail "watch-wiring: fm-pr-check.sh failed to arm"

  out="$dir/watch.out"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=0 FM_HEARTBEAT=999999 \
    FM_TEST_PR_STATE=MERGED FM_TEST_MERGEABLE_DIR="$mdir" "$WATCH" > "$out" &
  wait_for_exit "$!" 40 || fail "watch-wiring: watcher did not exit for the check wake"
  grep -F "check: $state/task-a.check.sh:" "$out" >/dev/null || fail "watch-wiring: watcher did not print the check wake"
  grep -F 'merged' "$out" >/dev/null || fail "watch-wiring: the merge line is missing from the wake"
  grep -F 'task-b PR https://github.com/example/repo/pull/71 now has a merge conflict with main' "$out" >/dev/null \
    || fail "watch-wiring: the sibling conflict line is missing from the wake"
  pass "the real watcher's check.sh sweep surfaces the merge and the sibling conflict as one wake"
}

test_mergeable_resolves_https_origin
test_mergeable_resolves_ssh_origin
test_mergeable_fails_without_origin
test_mergeable_fails_on_unparseable_origin
test_sweep_reports_dirty_sibling
test_sweep_silent_when_sibling_clean
test_sweep_silent_when_sibling_unstable
test_sweep_ignores_different_project
test_sweep_skips_non_pr_task
test_sweep_skips_self_and_is_noop_alone
test_sweep_noop_without_own_meta
test_sweep_dispatches_autoheal_once_per_head_oid
test_sweep_optout_stays_detect_only
test_generated_check_silent_while_pr_open
test_generated_check_reports_merge_and_sibling_conflict
test_watcher_surfaces_merge_and_conflict_as_one_wake
