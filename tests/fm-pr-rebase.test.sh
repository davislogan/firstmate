#!/usr/bin/env bash
# tests/fm-pr-rebase.test.sh - pure-git PR-branch auto-rebase mechanics
# (bin/fm-pr-rebase.sh), exercised end-to-end against local bare origins:
# no gh, no network, real clones, real rebases, real pushes.
#
# Matrix:
#   (a) clean rebase: head branch rebased onto the advanced default tip and
#       pushed with a lease; stdout reports old -> new OIDs; origin's branch
#       ref contains the new default tip
#   (b) genuine content conflict: exit 2, conflicting file named, rebase
#       aborted, origin's branch ref untouched
#   (c) no origin remote in the project clone: exit 1, clear error
#   (d) unreachable origin URL: exit 1, clear error
#   (e) push refused by the remote (hook stand-in for a lease race): exit 1,
#       origin's branch ref untouched
#   (f) no scratch-clone litter: the temp dir is cleaned on every path
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

REBASE="$ROOT/bin/fm-pr-rebase.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-rebase-tests)

# make_repo_pair <dir> <conflicting>: a bare origin (default branch main) with
# a feature branch fm/task-1 and a main that advanced AFTER the branch forked,
# plus a project clone of it. With <conflicting>=yes the main advance edits
# the same line the feature edited, so a rebase must raise a content conflict.
make_repo_pair() {
  local dir=$1 conflicting=$2 work
  work="$dir/work"
  git init -q --bare --initial-branch=main "$dir/origin.git"
  git clone -q "$dir/origin.git" "$work" 2>/dev/null
  printf 'line-one\nline-two\n' > "$work/shared.txt"
  git -C "$work" add shared.txt
  git -C "$work" commit -qm "seed"
  git -C "$work" push -q origin main
  git -C "$work" checkout -qb fm/task-1
  if [ "$conflicting" = yes ]; then
    printf 'feature-line-one\nline-two\n' > "$work/shared.txt"
  else
    printf 'feature\n' > "$work/feature.txt"
    git -C "$work" add feature.txt
  fi
  git -C "$work" add shared.txt 2>/dev/null || true
  git -C "$work" commit -qam "feature work"
  git -C "$work" push -q origin fm/task-1
  git -C "$work" checkout -q main
  if [ "$conflicting" = yes ]; then
    printf 'main-line-one\nline-two\n' > "$work/shared.txt"
  else
    printf 'line-one\nline-two\nmain-advance\n' > "$work/shared.txt"
  fi
  git -C "$work" commit -qam "main advance"
  git -C "$work" push -q origin main
  git clone -q "$dir/origin.git" "$dir/project" 2>/dev/null
}

assert_no_tmp_litter() {
  local tmpdir=$1 label=$2
  [ -z "$(find "$tmpdir" -mindepth 1 -print -quit 2>/dev/null)" ] \
    || fail "$label: scratch clone litter left under TMPDIR"
}

test_clean_rebase_pushes_with_lease() {
  local dir out old_head new_head main_tip
  dir="$TMP_ROOT/clean"
  mkdir -p "$dir/tmp"
  make_repo_pair "$dir" no
  old_head=$(git -C "$dir/origin.git" rev-parse refs/heads/fm/task-1)

  out=$(TMPDIR="$dir/tmp" "$REBASE" "$dir/project" fm/task-1) \
    || fail "clean: fm-pr-rebase.sh failed on a clean rebase"
  assert_contains "$out" "rebased onto main: $old_head -> " "clean: stdout did not report the rebase"

  new_head=$(git -C "$dir/origin.git" rev-parse refs/heads/fm/task-1)
  [ "$new_head" != "$old_head" ] || fail "clean: origin branch was not advanced"
  [ "${out##*-> }" = "$new_head" ] || fail "clean: reported new OID does not match origin's branch ref"
  main_tip=$(git -C "$dir/origin.git" rev-parse refs/heads/main)
  git -C "$dir/origin.git" merge-base --is-ancestor "$main_tip" "$new_head" \
    || fail "clean: rebased branch does not contain the new default tip"
  assert_no_tmp_litter "$dir/tmp" clean
  pass "clean rebase pushes the rebased head branch onto the advanced default tip"
}

test_content_conflict_aborts_untouched() {
  local dir out rc old_head
  dir="$TMP_ROOT/conflict"
  mkdir -p "$dir/tmp"
  make_repo_pair "$dir" yes
  old_head=$(git -C "$dir/origin.git" rev-parse refs/heads/fm/task-1)

  set +e
  out=$(TMPDIR="$dir/tmp" "$REBASE" "$dir/project" fm/task-1 2>"$dir/err")
  rc=$?
  set -e
  expect_code 2 "$rc" "conflict: a content conflict must exit 2"
  assert_contains "$out" "conflict: shared.txt" "conflict: the conflicting file was not named"
  [ "$(git -C "$dir/origin.git" rev-parse refs/heads/fm/task-1)" = "$old_head" ] \
    || fail "conflict: origin branch must be untouched after an aborted rebase"
  assert_no_tmp_litter "$dir/tmp" conflict
  pass "a genuine content conflict aborts with the remote untouched and names the files"
}

test_fails_without_origin_remote() {
  local dir rc
  dir="$TMP_ROOT/no-origin"
  mkdir -p "$dir/project" "$dir/tmp"
  git -C "$dir/project" init -q

  set +e
  TMPDIR="$dir/tmp" "$REBASE" "$dir/project" fm/task-1 >"$dir/out" 2>"$dir/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "no-origin: missing origin must be a mechanical failure"
  assert_grep 'no origin remote' "$dir/err" "no-origin: refusal did not explain the missing origin"
  assert_no_tmp_litter "$dir/tmp" no-origin
  pass "fm-pr-rebase.sh fails clearly when the project has no origin remote"
}

test_fails_on_unreachable_origin() {
  local dir rc
  dir="$TMP_ROOT/unreachable"
  mkdir -p "$dir/project" "$dir/tmp"
  git -C "$dir/project" init -q
  git -C "$dir/project" remote add origin "$dir/does-not-exist.git"

  set +e
  TMPDIR="$dir/tmp" "$REBASE" "$dir/project" fm/task-1 >"$dir/out" 2>"$dir/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "unreachable: unreachable origin must be a mechanical failure"
  assert_grep 'cannot resolve default branch' "$dir/err" "unreachable: refusal did not explain the unreachable origin"
  assert_no_tmp_litter "$dir/tmp" unreachable
  pass "fm-pr-rebase.sh fails clearly when the origin is unreachable"
}

test_refused_push_leaves_remote_untouched() {
  local dir rc old_head
  dir="$TMP_ROOT/push-refused"
  mkdir -p "$dir/tmp"
  make_repo_pair "$dir" no
  old_head=$(git -C "$dir/origin.git" rev-parse refs/heads/fm/task-1)
  # A hook rejection is the observable stand-in for any refused push,
  # including a lost --force-with-lease race: same failure surface, same
  # required behavior (mechanical exit, remote untouched).
  cat > "$dir/origin.git/hooks/pre-receive" <<'SH'
#!/usr/bin/env bash
echo "rejected by test hook" >&2
exit 1
SH
  chmod +x "$dir/origin.git/hooks/pre-receive"

  set +e
  TMPDIR="$dir/tmp" "$REBASE" "$dir/project" fm/task-1 >"$dir/out" 2>"$dir/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "push-refused: a refused push must be a mechanical failure"
  assert_grep 'push with lease' "$dir/err" "push-refused: refusal did not name the push"
  [ "$(git -C "$dir/origin.git" rev-parse refs/heads/fm/task-1)" = "$old_head" ] \
    || fail "push-refused: origin branch must be untouched after a refused push"
  assert_no_tmp_litter "$dir/tmp" push-refused
  pass "a refused push exits mechanically with the remote untouched"
}

test_clean_rebase_pushes_with_lease
test_content_conflict_aborts_untouched
test_fails_without_origin_remote
test_fails_on_unreachable_origin
test_refused_push_leaves_remote_untouched
