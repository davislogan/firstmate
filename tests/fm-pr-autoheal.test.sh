#!/usr/bin/env bash
# tests/fm-pr-autoheal.test.sh - the detached one-sibling heal orchestrator
# (bin/fm-pr-autoheal.sh): translating fm-pr-rebase.sh outcomes into the
# task's normal supervision channel (status-line wakes and a refreshed
# pr_head= meta line). The rebase helper is stubbed via FM_PR_REBASE_BIN;
# the real git mechanics are covered by tests/fm-pr-rebase.test.sh.
#
# Matrix:
#   (a) clean rebase: working: status FYI appended and pr_head= refreshed to
#       the new OID (tail -1 supersedes the stale recorded head)
#   (b) content conflict: blocked: status naming the conflicting files plus a
#       crew-liveness hint, exit 2
#   (c) unresolvable PR head branch: blocked: status, rebase stub never runs
#   (d) mechanical rebase failure: blocked: "could not run" status carrying
#       the helper's stderr reason
#   (e) meta lacking pr=: hard error, no status write
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

AUTOHEAL="$ROOT/bin/fm-pr-autoheal.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-autoheal-tests)

PR_URL="https://github.com/example/repo/pull/71"

# make_case <name>: state dir with a task meta, a gh mock answering
# headRefName from FM_TEST_HEAD_BRANCH, a tmux mock that always fails (so the
# liveness probe stays hermetic), and a rebase stub driven by
# FM_TEST_REBASE_OUT / FM_TEST_REBASE_ERR / FM_TEST_REBASE_RC that records
# each invocation to rebase.log. Echoes the case dir.
make_case() {
  local name=$1 dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/state" "$dir/fakebin"
  fm_write_meta "$dir/state/task-s1.meta" \
    "window=fm-task-s1" \
    "project=$dir/project" \
    "kind=ship" \
    "mode=no-mistakes" \
    "pr=$PR_URL"
  cat > "$dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr view")
    case " $* " in
      *headRefName*) printf '%s\n' "${FM_TEST_HEAD_BRANCH:-}" ;;
    esac
    exit 0 ;;
esac
exit 1
SH
  cat > "$dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  cat > "$dir/fakebin/rebase-stub" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_REBASE_LOG"
[ -n "${FM_TEST_REBASE_OUT:-}" ] && printf '%s\n' "$FM_TEST_REBASE_OUT"
[ -n "${FM_TEST_REBASE_ERR:-}" ] && printf '%s\n' "$FM_TEST_REBASE_ERR" >&2
exit "${FM_TEST_REBASE_RC:-0}"
SH
  chmod +x "$dir/fakebin/gh" "$dir/fakebin/tmux" "$dir/fakebin/rebase-stub"
  printf '%s\n' "$dir"
}

run_autoheal() {
  local dir=$1
  FM_TEST_REBASE_LOG="$dir/rebase.log" \
  FM_PR_REBASE_BIN="$dir/fakebin/rebase-stub" \
  PATH="$dir/fakebin:$PATH" \
    "$AUTOHEAL" task-s1 "$dir/state" >"$dir/out" 2>"$dir/err"
}

test_clean_rebase_writes_fyi_and_refreshes_pr_head() {
  local dir
  dir=$(make_case clean)
  printf 'pr_head=oldoldold\n' >> "$dir/state/task-s1.meta"

  FM_TEST_HEAD_BRANCH=fm/task-s1 \
  FM_TEST_REBASE_OUT="rebased onto main: 1111aaaa -> 2222bbbb" \
    run_autoheal "$dir" || fail "clean: fm-pr-autoheal.sh failed on a clean rebase"

  assert_grep "working: PR $PR_URL auto-rebased onto main" "$dir/state/task-s1.status" \
    "clean: no working: FYI status line"
  assert_grep 'verify they return green' "$dir/state/task-s1.status" \
    "clean: FYI does not ask for a checks re-verify"
  [ "$(grep '^pr_head=' "$dir/state/task-s1.meta" | tail -1)" = "pr_head=2222bbbb" ] \
    || fail "clean: pr_head= was not refreshed to the rebased OID"
  assert_grep "$dir/project fm/task-s1" "$dir/rebase.log" \
    "clean: rebase helper did not get the project dir and head branch"
  pass "a clean rebase appends the working: FYI and refreshes pr_head="
}

test_conflict_writes_blocked_with_files_and_liveness() {
  local dir rc
  dir=$(make_case conflict)

  set +e
  FM_TEST_HEAD_BRANCH=fm/task-s1 \
  FM_TEST_REBASE_OUT="conflict: src/app.ts docs/x.md" \
  FM_TEST_REBASE_RC=2 \
    run_autoheal "$dir"
  rc=$?
  set -e
  expect_code 2 "$rc" "conflict: autoheal should propagate the conflict exit"
  assert_grep "blocked: PR $PR_URL conflicts with the default branch" "$dir/state/task-s1.status" \
    "conflict: no blocked: status line"
  assert_grep 'conflicts: src/app.ts docs/x.md' "$dir/state/task-s1.status" \
    "conflict: conflicting files were not named"
  assert_grep 'crew agent ' "$dir/state/task-s1.status" \
    "conflict: crew-liveness hint missing"
  assert_grep 'steer it to rebase, or respawn/escalate' "$dir/state/task-s1.status" \
    "conflict: remediation hint missing"
  pass "a content conflict appends a blocked: status with files and a liveness hint"
}

test_unresolvable_head_branch_blocks_without_rebase() {
  local dir rc
  dir=$(make_case no-head)

  set +e
  FM_TEST_HEAD_BRANCH='' run_autoheal "$dir"
  rc=$?
  set -e
  expect_code 1 "$rc" "no-head: unresolvable head branch should exit 1"
  assert_grep 'could not resolve the PR head branch' "$dir/state/task-s1.status" \
    "no-head: blocked: status does not name the resolution failure"
  [ ! -f "$dir/rebase.log" ] || fail "no-head: rebase helper must not run without a head branch"
  pass "an unresolvable PR head branch blocks without attempting a rebase"
}

test_mechanical_failure_carries_reason() {
  local dir rc
  dir=$(make_case mechanical)

  set +e
  FM_TEST_HEAD_BRANCH=fm/task-s1 \
  FM_TEST_REBASE_ERR="fm-pr-rebase: fetch of main and fm/task-s1 from origin failed" \
  FM_TEST_REBASE_RC=1 \
    run_autoheal "$dir"
  rc=$?
  set -e
  expect_code 1 "$rc" "mechanical: helper failure should exit 1"
  assert_grep 'auto-rebase could not run (fm-pr-rebase: fetch' "$dir/state/task-s1.status" \
    "mechanical: blocked: status does not carry the helper reason"
  pass "a mechanical rebase failure blocks with the helper's reason"
}

test_meta_without_pr_is_hard_error() {
  local dir rc
  dir="$TMP_ROOT/no-pr"
  mkdir -p "$dir/state" "$dir/fakebin"
  fm_write_meta "$dir/state/task-s1.meta" "window=fm-task-s1" "project=$dir/project"

  set +e
  "$AUTOHEAL" task-s1 "$dir/state" >"$dir/out" 2>"$dir/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "no-pr: meta without pr= should be a hard error"
  assert_grep 'lacks project= or pr=' "$dir/err" "no-pr: error does not name the missing meta field"
  [ ! -f "$dir/state/task-s1.status" ] || fail "no-pr: no status line may be written without a pr="
  pass "meta without pr= is a hard error with no status write"
}

test_clean_rebase_writes_fyi_and_refreshes_pr_head
test_conflict_writes_blocked_with_files_and_liveness
test_unresolvable_head_branch_blocks_without_rebase
test_mechanical_failure_carries_reason
test_meta_without_pr_is_hard_error
