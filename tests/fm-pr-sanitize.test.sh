#!/usr/bin/env bash
# tests/fm-pr-sanitize.test.sh - the PR title/body unicode-dash sanitize
# (bin/fm-pr-sanitize.sh): every covered dash becomes a plain ASCII hyphen,
# the edit happens only when something changed, and re-running is a no-op.
#
# Matrix:
#   (a) dirty title and body: gh-axi pr edit called with number + --repo, the
#       edited body is fully ASCII across all ten covered dashes, the edited
#       title is sanitized, and one summary line is printed
#   (b) clean title and body: no edit call, no output
#   (c) idempotence: a second run over already-sanitized text makes no edit
#   (d) malformed PR URL: fails fast without reading or editing
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SANITIZE="$ROOT/bin/fm-pr-sanitize.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-sanitize-tests)

PR_URL="https://github.com/example/repo/pull/71"

# All ten covered dashes as UTF-8 byte strings, mirrored from the script's
# documented set so the fixture provably exercises each codepoint.
D2010=$'\xe2\x80\x90' D2011=$'\xe2\x80\x91' D2012=$'\xe2\x80\x92'
D2013=$'\xe2\x80\x93' D2014=$'\xe2\x80\x94' D2015=$'\xe2\x80\x95'
D2212=$'\xe2\x88\x92' DFE58=$'\xef\xb9\x98' DFE63=$'\xef\xb9\xa3'
DFF0D=$'\xef\xbc\x8d'

# make_case <name>: fakebin with a gh mock serving title/body from case files
# and a gh-axi mock recording its args and capturing --title/--body-file
# values. Echoes the case dir.
make_case() {
  local name=$1 dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/fakebin"
  cat > "$dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr view")
    case " $* " in
      *"--json title"*) cat "$FM_TEST_PR_TITLE_FILE" ;;
      *"--json body"*) cat "$FM_TEST_PR_BODY_FILE" ;;
    esac
    exit 0 ;;
esac
exit 1
SH
  cat > "$dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
prev=
for a in "$@"; do
  [ "$prev" = "--body-file" ] && cp "$a" "$FM_TEST_BODY_CAPTURE"
  [ "$prev" = "--title" ] && printf '%s\n' "$a" > "$FM_TEST_TITLE_CAPTURE"
  prev=$a
done
exit 0
SH
  chmod +x "$dir/fakebin/gh" "$dir/fakebin/gh-axi"
  printf '%s\n' "$dir"
}

run_sanitize() {
  local dir=$1
  FM_TEST_PR_TITLE_FILE="$dir/title" \
  FM_TEST_PR_BODY_FILE="$dir/body" \
  FM_TEST_GH_AXI_LOG="$dir/gh-axi.log" \
  FM_TEST_BODY_CAPTURE="$dir/body.edited" \
  FM_TEST_TITLE_CAPTURE="$dir/title.edited" \
  PATH="$dir/fakebin:$PATH" \
    "$SANITIZE" "$PR_URL" >"$dir/out" 2>"$dir/err"
}

test_dirty_title_and_body_are_sanitized() {
  local dir
  dir=$(make_case dirty)
  printf '%s\n' "feat: title ${D2014} with em ${D2013} and en" > "$dir/title"
  {
    printf 'a%sb\n' "$D2010" "$D2011" "$D2012" "$D2013" "$D2014"
    printf 'a%sb\n' "$D2015" "$D2212" "$DFE58" "$DFE63" "$DFF0D"
  } > "$dir/body"

  run_sanitize "$dir" || fail "dirty: fm-pr-sanitize.sh failed"

  assert_grep 'pr edit 71 --repo example/repo' "$dir/gh-axi.log" \
    "dirty: gh-axi pr edit was not called with number and --repo"
  [ "$(cat "$dir/title.edited")" = "feat: title - with em - and en" ] \
    || fail "dirty: edited title still carries unicode dashes"
  printf 'a-b\na-b\na-b\na-b\na-b\na-b\na-b\na-b\na-b\na-b\n' > "$dir/body.expected"
  diff -q "$dir/body.expected" "$dir/body.edited" >/dev/null \
    || fail "dirty: edited body is not the fully ASCII transliteration"
  assert_grep 'sanitized unicode dashes in PR #71' "$dir/out" \
    "dirty: no summary line was printed"
  pass "a dirty title and body are transliterated across all ten covered dashes"
}

test_clean_pr_makes_no_edit() {
  local dir
  dir=$(make_case clean)
  printf 'feat: plain title - nothing fancy\n' > "$dir/title"
  printf 'plain body - already ASCII\n' > "$dir/body"

  run_sanitize "$dir" || fail "clean: fm-pr-sanitize.sh failed"

  [ ! -s "$dir/gh-axi.log" ] || fail "clean: an already-clean PR must not be edited"
  [ ! -s "$dir/out" ] || fail "clean: an already-clean PR must print nothing"
  pass "an already-clean PR makes no edit call and prints nothing"
}

test_second_run_is_idempotent() {
  local dir
  dir=$(make_case idempotent)
  printf 'feat: title %s once\n' "$D2014" > "$dir/title"
  printf 'body %s once\n' "$D2013" > "$dir/body"
  run_sanitize "$dir" || fail "idempotent: first run failed"
  [ -s "$dir/gh-axi.log" ] || fail "idempotent: first run should have edited"

  # The PR now serves the sanitized text; a rerun must not edit again.
  cat "$dir/title.edited" > "$dir/title"
  cat "$dir/body.edited" > "$dir/body"
  : > "$dir/gh-axi.log"
  run_sanitize "$dir" || fail "idempotent: second run failed"
  [ ! -s "$dir/gh-axi.log" ] || fail "idempotent: second run must make no edit"
  pass "re-running over already-sanitized text makes no second edit"
}

test_malformed_url_fails_fast() {
  local dir rc
  dir=$(make_case malformed)

  set +e
  PATH="$dir/fakebin:$PATH" "$SANITIZE" "https://example.com/not/github" >"$dir/out" 2>"$dir/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "malformed: a non-GitHub PR URL must fail"
  assert_grep 'PR URL must match' "$dir/err" "malformed: refusal did not explain the URL shape"
  pass "a malformed PR URL fails fast"
}

test_dirty_title_and_body_are_sanitized
test_clean_pr_makes_no_edit
test_second_run_is_idempotent
test_malformed_url_fails_fast
