#!/usr/bin/env bash
# Behavior tests for mail mode: the mailbox poll (fm-mail-poll.sh), bootstrap's
# .env-presence activation, request ingest and the safe zip extractor,
# draft replies, task link/follow-up, and the retention prune.
#
# Mail mode must be INERT by default (no FM_MAIL_INTAKE/FM_MAIL_CAPTAIN -> the
# poll never calls mail-axi and bootstrap writes/prints nothing) and additive
# when on. mail-axi is a fakebin stub driven by FAKE_* env so these stay
# hermetic; jq and python3 are the real tools.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-mail-mode-tests)
TENANT=b9726fce-0000-0000-0000-000000000000
CAPTAIN=captain@example.com

# A fakebin mail-axi that mimics the contract in docs/configuration.md
# "Mail mode (.env)". Every call is logged one argv per line to FAKE_MAIL_LOG.
make_fake_mail_axi() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/mail-axi" <<'SH'
#!/usr/bin/env bash
[ -n "${FAKE_MAIL_LOG:-}" ] && printf '%s\n' "$*" >> "$FAKE_MAIL_LOG"
cmd=$1; shift
opt() { local want=$1; shift; while [ $# -gt 0 ]; do [ "$1" = "$want" ] && { printf '%s' "$2"; return; }; shift; done; }
case "$cmd" in
  intake)
    stash=$(opt --stash-dir "$@")
    case "${FAKE_INTAKE_MODE:-empty}" in
      empty) printf '{"accepted":[],"rejected":0,"errors":[]}\n' ;;
      accept)
        ids=()
        for f in "$FAKE_STASH_SRC"/*.json; do cp "$f" "$stash/"; ids+=("\"$(basename "$f" .json)\""); done
        printf '{"accepted":[%s],"rejected":1,"errors":[]}\n' "$(IFS=,; echo "${ids[*]}")" ;;
      raw) printf '%s\n' "$FAKE_INTAKE_RAW" ;;
      fail) echo "graph auth failed: token expired" >&2; exit 3 ;;
      sleep) sleep 5; printf '{"accepted":[]}\n' ;;
    esac ;;
  save-attachments)
    [ -n "${FAKE_SAVE_FAIL:-}" ] && { echo "save failed" >&2; exit 1; }
    dest=$(opt --dir "$@")
    cp "$FAKE_ATTACH_SRC"/* "$dest/" ;;
  reply-draft)
    [ -n "${FAKE_REPLY_FAIL:-}" ] && exit 1
    echo "draft-123" ;;
  reply-send)
    [ -n "${FAKE_REPLY_FAIL:-}" ] && exit 1
    echo "sent-456" ;;
  move)
    [ -n "${FAKE_MOVE_FAIL:-}" ] && exit 1
    echo moved ;;
esac
exit 0
SH
  chmod +x "$fakebin/mail-axi"
  printf '%s\n' "$fakebin"
}

# make_home <name>: a home with mail mode configured in .env.
make_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/data"
  printf 'FM_MAIL_INTAKE=firstmate@example.com\nFM_MAIL_CAPTAIN=%s\nFM_MAIL_TENANT=%s\n' "$CAPTAIN" "$TENANT" > "$home/.env"
  printf '%s\n' "$home"
}

# write_stash <path> <req> [jq-filter]: a T1 stash per the contract schema.
write_stash() {
  local path=$1 req=$2 filter=${3:-.}
  jq -n --arg req "$req" --arg from "$CAPTAIN" --arg tenant "$TENANT" '{
    req: $req, graphId: "AAkALgAA-graph_id=", internetMessageId: ("<" + $req + "@example.com>"),
    conversationId: "conv", from: $from, received: "2026-10-10T14:12:03Z", subject: "recipes",
    trust: {tier: "T1", authAs: "Internal", tenant: $tenant, directionality: "Originating"},
    instruction: "aggregate the acids; $(touch /tmp/pwned) `id`",
    attachments: []
  }' | jq "$filter" > "$path"
}

# zip_py <out.zip> <python-body>: build a crafted zip with the stdlib.
zip_py() {
  python3 -I - "$1" "$2" <<'PY'
import sys, zipfile, io
out = sys.argv[1]
z = zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED)
exec(sys.argv[2], {"z": z, "zipfile": zipfile, "io": io})
z.close()
PY
}

run_poll() {
  local home=$1 fakebin=$2
  PATH="$fakebin:$PATH" FM_HOME="$home" FAKE_MAIL_LOG="$home/mail.log" "$ROOT/bin/fm-mail-poll.sh"
}

# --- poll ------------------------------------------------------------------

test_poll_inert_without_config() {
  local home fakebin out
  home="$TMP_ROOT/poll-off"; mkdir -p "$home"
  fakebin=$(make_fake_mail_axi "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FAKE_MAIL_LOG="$home/mail.log" \
    FM_MAIL_INTAKE='' FM_MAIL_CAPTAIN='' "$ROOT/bin/fm-mail-poll.sh"); expect_code 0 $? "poll off exit"
  [ -z "$out" ] || fail "poll must be silent when mail mode is off (got: $out)"
  assert_absent "$home/mail.log" "poll must not call mail-axi when mail mode is off"
  assert_absent "$home/state/mail-inbox" "poll must not create an inbox when off"
  pass "fm-mail-poll is a hard no-op without mail-mode config"
}

test_poll_empty_is_silent() {
  local home fakebin out
  home=$(make_home poll-empty); fakebin=$(make_fake_mail_axi "$home")
  out=$(run_poll "$home" "$fakebin")
  [ -z "$out" ] || fail "an empty intake must not wake (got: $out)"
  assert_grep "intake --mailbox firstmate@example.com --stash-dir $home/state/mail-inbox --allow-from $CAPTAIN --tenant $TENANT --json" \
    "$home/mail.log" "poll must call mail-axi intake per the contract"
  pass "fm-mail-poll stays silent when nothing was accepted"
}

test_poll_wake_line() {
  local home fakebin out src
  home=$(make_home poll-wake); fakebin=$(make_fake_mail_axi "$home")
  src="$home/src1"; mkdir -p "$src"
  write_stash "$src/20261010-1412-a3f9c1.json" 20261010-1412-a3f9c1
  out=$(FAKE_INTAKE_MODE=accept FAKE_STASH_SRC="$src" run_poll "$home" "$fakebin")
  [ "$out" = "mail-request 20261010-1412-a3f9c1" ] || fail "single accept wake line wrong (got: $out)"
  src="$home/src3"; mkdir -p "$src"
  write_stash "$src/20261010-1500-aaaaaa.json" 20261010-1500-aaaaaa
  write_stash "$src/20261010-1501-bbbbbb.json" 20261010-1501-bbbbbb
  write_stash "$src/20261010-1502-cccccc.json" 20261010-1502-cccccc
  out=$(FAKE_INTAKE_MODE=accept FAKE_STASH_SRC="$src" run_poll "$home" "$fakebin")
  [ "$out" = "mail-request 20261010-1500-aaaaaa (+2)" ] || fail "batch wake line wrong (got: $out)"
  pass "fm-mail-poll prints one mail-request line with a (+N) batch suffix"
}

test_poll_ignores_unsafe_or_unstashed_ids() {
  local home fakebin out
  home=$(make_home poll-unsafe); fakebin=$(make_fake_mail_axi "$home")
  out=$(FAKE_INTAKE_MODE=raw FAKE_INTAKE_RAW='{"accepted":["../etc","20261010-0000-ffffff"],"rejected":0,"errors":[]}' \
    run_poll "$home" "$fakebin")
  [ -z "$out" ] || fail "unsafe or unstashed ids must not wake (got: $out)"
  pass "fm-mail-poll ignores unsafe ids and ids with no stash file"
}

test_poll_rewakes_for_stranded_stashes() {
  local home fakebin out inbox
  home=$(make_home poll-pending); fakebin=$(make_fake_mail_axi "$home")
  inbox="$home/state/mail-inbox"; mkdir -p "$inbox/untrusted"
  write_stash "$inbox/untrusted/20261010-0900-eeeeee.json" 20261010-0900-eeeeee
  out=$(FM_MAIL_NOW_OVERRIDE=1000 run_poll "$home" "$fakebin")
  [ -z "$out" ] || fail "quarantined stashes must not wake (got: $out)"
  write_stash "$inbox/20261010-1001-bbbbbb.json" 20261010-1001-bbbbbb
  write_stash "$inbox/20261010-1000-aaaaaa.json" 20261010-1000-aaaaaa
  out=$(FM_MAIL_NOW_OVERRIDE=1000 run_poll "$home" "$fakebin")
  [ "$out" = "mail-request 20261010-1000-aaaaaa (+1)" ] || fail "stranded stashes must wake for the oldest (got: $out)"
  out=$(FM_MAIL_NOW_OVERRIDE=1060 run_poll "$home" "$fakebin")
  [ -z "$out" ] || fail "an unchanged pending set must not re-wake every poll (got: $out)"
  rm -f "$inbox/20261010-1000-aaaaaa.json"
  out=$(FM_MAIL_NOW_OVERRIDE=1120 run_poll "$home" "$fakebin")
  [ "$out" = "mail-request 20261010-1001-bbbbbb" ] || fail "a changed pending set must re-wake (got: $out)"
  out=$(FM_MAIL_NOW_OVERRIDE=2000 run_poll "$home" "$fakebin")
  [ -z "$out" ] || fail "the reminder must wait out the rewake interval (got: $out)"
  out=$(FM_MAIL_NOW_OVERRIDE=2920 run_poll "$home" "$fakebin")
  [ "$out" = "mail-request 20261010-1001-bbbbbb" ] || fail "the reminder must repeat after the rewake interval (got: $out)"
  rm -f "$inbox/20261010-1001-bbbbbb.json"
  out=$(FM_MAIL_NOW_OVERRIDE=2980 run_poll "$home" "$fakebin")
  [ -z "$out" ] || fail "an empty inbox must be silent (got: $out)"
  assert_absent "$home/state/mail-poll.pending" "an empty inbox must clear the pending marker"
  write_stash "$inbox/20261010-1100-cccccc.json" 20261010-1100-cccccc
  out=$(FAKE_INTAKE_MODE=fail FM_MAIL_NOW_OVERRIDE=3000 run_poll "$home" "$fakebin")
  assert_contains "$out" "mail-intake-error mail-axi intake failed" "a new intake failure must surface first"
  out=$(FAKE_INTAKE_MODE=fail FM_MAIL_NOW_OVERRIDE=3060 run_poll "$home" "$fakebin")
  [ "$out" = "mail-request 20261010-1100-cccccc" ] || fail "a repeated failure must still remind about stranded stashes (got: $out)"
  out=$(FAKE_INTAKE_MODE=fail FM_MAIL_NOW_OVERRIDE=3120 run_poll "$home" "$fakebin")
  [ -z "$out" ] || fail "the failure-path reminder must stay rate-limited (got: $out)"
  out=$(FM_MAIL_TENANT='' FM_MAIL_NOW_OVERRIDE=3180 run_poll "$home" "$fakebin")
  assert_contains "$out" "mail-intake-error missing FM_MAIL_TENANT" "a config failure must surface"
  out=$(FM_MAIL_TENANT='' FM_MAIL_NOW_OVERRIDE=5000 run_poll "$home" "$fakebin")
  [ "$out" = "mail-request 20261010-1100-cccccc" ] || fail "a repeated config failure must remind after the interval (got: $out)"
  rm -f "$inbox/20261010-1100-cccccc.json"
  pass "fm-mail-poll re-wakes for stranded stashes, rate-limited by pending set and interval, even while intake fails"
}

test_poll_error_rate_limited() {
  local home fakebin out
  home=$(make_home poll-err); fakebin=$(make_fake_mail_axi "$home")
  out=$(FAKE_INTAKE_MODE=fail run_poll "$home" "$fakebin")
  assert_contains "$out" "mail-intake-error mail-axi intake failed (exit 3): graph auth failed" "first failure must surface"
  out=$(FAKE_INTAKE_MODE=fail run_poll "$home" "$fakebin")
  [ -z "$out" ] || fail "a repeated identical failure must stay quiet (got: $out)"
  out=$(FAKE_INTAKE_MODE=raw FAKE_INTAKE_RAW='not json' run_poll "$home" "$fakebin")
  assert_contains "$out" "mail-intake-error mail-axi intake returned unparseable output" "a new error must surface"
  out=$(run_poll "$home" "$fakebin")
  [ -z "$out" ] || fail "a clean poll must be silent"
  assert_absent "$home/state/mail-poll.error" "a clean poll must clear the error marker"
  out=$(FAKE_INTAKE_MODE=fail run_poll "$home" "$fakebin")
  assert_contains "$out" "mail-intake-error" "the failure must surface again after recovery"
  out=$(FAKE_INTAKE_MODE=raw FAKE_INTAKE_RAW='{"accepted":[],"errors":["mailbox not allowed"]}' run_poll "$home" "$fakebin")
  assert_contains "$out" "mail-intake-error mail-axi intake reported 1 error(s): mailbox not allowed" "reported errors must surface"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_MAIL_TENANT='' "$ROOT/bin/fm-mail-poll.sh")
  assert_contains "$out" "mail-intake-error missing FM_MAIL_TENANT" "a missing tenant must surface"
  pass "fm-mail-poll reports failures once per distinct message"
}

test_poll_timeout() {
  local home fakebin out
  command -v timeout >/dev/null 2>&1 || { pass "fm-mail-poll timeout (skipped: no timeout binary)"; return; }
  home=$(make_home poll-timeout); fakebin=$(make_fake_mail_axi "$home")
  out=$(FAKE_INTAKE_MODE=sleep FM_MAIL_POLL_TIMEOUT=1 run_poll "$home" "$fakebin")
  assert_contains "$out" "mail-intake-error mail-axi intake timed out after 1s" "a hung mail-axi must time out"
  pass "fm-mail-poll bounds the mail-axi call inside the check timeout"
}

# --- bootstrap -------------------------------------------------------------

test_bootstrap_opt_in_and_out() {
  local home fakebin out sum1 sum2 v
  home=$(make_home boot); fakebin=$(make_fake_mail_axi "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
  assert_contains "$out" "MAIL: mail mode on" "bootstrap must announce mail mode"
  [ -x "$home/state/mail-watch.check.sh" ] || fail "the check shim must exist and be executable"
  assert_grep "fm-mail-poll.sh" "$home/state/mail-watch.check.sh" "the shim must exec the poll"
  assert_present "$home/config/mail-mode.env" "bootstrap must write the cadence config"
  # shellcheck source=/dev/null
  v=$(unset FM_CHECK_INTERVAL; . "$home/config/mail-mode.env"; bash -c 'echo $FM_CHECK_INTERVAL')
  [ "$v" = 60 ] || fail "mail cadence must export 60 (got $v)"
  # shellcheck source=/dev/null
  v=$(FM_CHECK_INTERVAL=300 bash -c '. "$1"; echo "$FM_CHECK_INTERVAL"' _ "$home/config/mail-mode.env")
  [ "$v" = 60 ] || fail "mail cadence must lower a higher interval (got $v)"
  printf 'export FM_CHECK_INTERVAL=30\n' > "$home/xmode.env"
  # shellcheck disable=SC2016 # $1/$2 expand in the child shell.
  v=$(env -u FM_CHECK_INTERVAL bash -c '. "$1"; . "$2"; echo "$FM_CHECK_INTERVAL"' _ "$home/xmode.env" "$home/config/mail-mode.env")
  [ "$v" = 30 ] || fail "X then mail must keep the lower 30 (got $v)"
  # shellcheck disable=SC2016 # $1/$2 expand in the child shell.
  v=$(env -u FM_CHECK_INTERVAL bash -c '. "$1"; . "$2"; echo "$FM_CHECK_INTERVAL"' _ "$home/config/mail-mode.env" "$home/xmode.env")
  [ "$v" = 30 ] || fail "mail then X must keep the lower 30 (got $v)"
  sum1=$(cat "$home/state/mail-watch.check.sh" "$home/config/mail-mode.env" | shasum)
  PATH="$fakebin:$PATH" FM_HOME="$home" "$ROOT/bin/fm-bootstrap.sh" >/dev/null 2>&1
  sum2=$(cat "$home/state/mail-watch.check.sh" "$home/config/mail-mode.env" | shasum)
  [ "$sum1" = "$sum2" ] || fail "bootstrap mail-mode setup must be idempotent"
  printf 'FM_MAIL_INTAKE=\n' > "$home/.env"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
  assert_contains "$out" "MAIL: mail mode off" "opt-out must report the cleanup"
  assert_absent "$home/state/mail-watch.check.sh" "opt-out must remove the shim"
  assert_absent "$home/config/mail-mode.env" "opt-out must remove the cadence"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
  assert_not_contains "$out" "MAIL:" "steady-state off must be silent"
  pass "bootstrap arms mail mode from .env idempotently, lower cadence wins, and opt-out cleans up"
}

test_bootstrap_missing_mail_axi() {
  local home out
  home=$(make_home boot-missing)
  out=$(PATH="/usr/bin:/bin" FM_HOME="$home" "$BASH" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
  assert_contains "$out" "MAIL: mail mode off - missing" "a missing mail-axi must be reported"
  assert_contains "$out" "mail-axi" "the report must name mail-axi"
  assert_absent "$home/state/mail-watch.check.sh" "a missing dependency must not arm the shim"
  pass "bootstrap refuses to arm mail mode without mail-axi"
}

test_supervision_instructions_source_mail_cadence() {
  local home out
  home="$TMP_ROOT/sup"; mkdir -p "$home/config"
  : > "$home/config/mail-mode.env"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-supervision-instructions.sh" --harness grok)
  assert_contains "$out" "- Mail mode: active; source $home/config/mail-mode.env" "the block must state mail cadence"
  assert_contains "$out" "[ -f '$home/config/mail-mode.env' ] && . '$home/config/mail-mode.env'; exec bin/fm-watch-arm.sh" \
    "the grok arm must source the mail cadence"
  assert_not_contains "$out" "__FM_MAIL_MODE_ENV" "placeholders must be rendered"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-supervision-instructions.sh" --harness claude --repair-line)
  assert_contains "$out" "source '$home/config/mail-mode.env' first" "the repair line must source the mail cadence"
  : > "$home/config/x-mode.env"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-supervision-instructions.sh" --harness claude --repair-line)
  assert_contains "$out" "source '$home/config/x-mode.env' and '$home/config/mail-mode.env' first" "both cadences must be sourced"
  pass "supervision instructions source the mail-mode cadence"
}

# --- unzip -----------------------------------------------------------------

test_unzip_extracts_and_nests_one_level() {
  local d out
  d="$TMP_ROOT/unzip-ok"; mkdir -p "$d"
  zip_py "$d/a.zip" '
inner = io.BytesIO()
iz = zipfile.ZipFile(inner, "w")
iz.writestr("deep.txt", "deep")
deeper = io.BytesIO(); dz = zipfile.ZipFile(deeper, "w"); dz.writestr("x.txt", "x"); dz.close()
iz.writestr("too-deep.zip", deeper.getvalue())
iz.close()
z.writestr("docs/recipe.txt", "citric 3g")
z.writestr("inner.zip", inner.getvalue())'
  out=$("$ROOT/bin/fm-mail-unzip.sh" "$d/a.zip" "$d/out"); expect_code 0 $? "unzip ok exit"
  assert_contains "$out" '"ok": true' "a clean archive must extract"
  assert_present "$d/out/docs/recipe.txt" "top-level file extracted"
  assert_present "$d/out/inner.zip.unzipped/deep.txt" "one nested level extracted"
  assert_absent "$d/out/inner.zip.unzipped/too-deep.zip" "a second nesting level must not be written"
  assert_contains "$out" "nested archive beyond one level" "the skipped deeper archive must be reported"
  [ "$(stat -c %a "$d/out/docs/recipe.txt" 2>/dev/null || stat -f %Lp "$d/out/docs/recipe.txt")" = 600 ] || fail "files must be 0600"
  pass "fm-mail-unzip extracts with one nesting level and 0600 files"
}

# expect_refused <name> <python-body> <reason-substring> [env...]
expect_refused() {
  local name=$1 body=$2 reason=$3 d out rc
  shift 3
  d="$TMP_ROOT/unzip-$name"; mkdir -p "$d"
  zip_py "$d/a.zip" "$body"
  out=$(env "$@" "$ROOT/bin/fm-mail-unzip.sh" "$d/a.zip" "$d/out"); rc=$?
  expect_code 3 "$rc" "unzip $name exit"
  assert_contains "$out" "$reason" "unzip $name reason"
  assert_absent "$d/out" "a refused archive ($name) must write nothing"
  [ -z "$(find "$d" -name '.fm-mail-unzip.*')" ] || fail "a refused archive ($name) must leave no temp dir"
}

test_unzip_limits() {
  expect_refused traversal 'z.writestr("../evil.txt", "x")' "parent-directory entry"
  expect_refused absolute 'z.writestr("/etc/evil", "x")' "absolute path entry"
  expect_refused backslash 'z.writestr("a\\..\\..\\evil", "x")' "parent-directory entry"
  expect_refused symlink '
i = zipfile.ZipInfo("link"); i.external_attr = (0o120777 << 16)
z.writestr(i, "/etc/passwd")' "symlink or special entry"
  expect_refused entries 'for n in range(6): z.writestr("f%d" % n, "x")' "too many entries" FM_MAIL_ZIP_MAX_ENTRIES=5
  expect_refused ratio 'z.writestr("bomb", "0" * 2000000)' "compression ratio"
  expect_refused size 'z.writestr("big", bytes(range(256)) * 40)' "too large uncompressed" FM_MAIL_ZIP_MAX_BYTES=1000
  expect_refused duplicate 'z.writestr("a.txt", "1"); z.writestr("A.txt", "2")' "duplicate entry"
  local d="$TMP_ROOT/unzip-exists"; mkdir -p "$d/out"
  zip_py "$d/a.zip" 'z.writestr("a.txt", "1")'
  "$ROOT/bin/fm-mail-unzip.sh" "$d/a.zip" "$d/out" >/dev/null 2>&1; expect_code 2 $? "unzip into an existing dest"
  pass "fm-mail-unzip refuses traversal, absolute, symlink, entry, ratio, size, and duplicate violations atomically"
}

# --- ingest ----------------------------------------------------------------

ingest() {
  local home=$1 fakebin=$2; shift 2
  PATH="$fakebin:$PATH" FM_HOME="$home" FAKE_MAIL_LOG="$home/mail.log" "$ROOT/bin/fm-mail-ingest.sh" "$@"
}

test_ingest_ok_duplicate_untrusted_toobig() {
  local home fakebin out req=20261010-1412-a3f9c1 dir att
  home=$(make_home ingest); fakebin=$(make_fake_mail_axi "$home")
  mkdir -p "$home/state/mail-inbox"
  write_stash "$home/state/mail-inbox/$req.json" "$req" '.attachments = [{"id":"a1","name":"r.zip","type":"application/zip","bytes":400}]'
  att="$home/att"; mkdir -p "$att"
  zip_py "$att/r.zip" 'z.writestr("recipe.txt", "malic 2g")'
  out=$(FAKE_ATTACH_SRC="$att" ingest "$home" "$fakebin" "$req"); expect_code 0 $? "ingest ok exit"
  dir="$home/data/mail-requests/$req"
  assert_contains "$out" "ok $req" "ingest must report ok"
  assert_contains "$out" "unzipped r.zip: 1 file(s)" "ingest must unzip zip attachments"
  assert_present "$dir/in/unzipped/r.zip/recipe.txt" "the zip must be extracted under in/unzipped"
  # shellcheck disable=SC2016 # the literal command substitution must be stored, never run.
  assert_grep 'aggregate the acids; $(touch /tmp/pwned)' "$dir/instruction.txt" "the instruction must be stored verbatim"
  assert_absent "$home/state/mail-inbox/$req.json" "ingest must drain the inbox file"
  assert_grep "save-attachments AAkALgAA-graph_id= --dir $dir/in --mailbox firstmate@example.com" "$home/mail.log" "attachments saved via mail-axi"
  # Same message re-stashed under the same id: duplicate.
  write_stash "$home/state/mail-inbox/$req.json" "$req"
  out=$(ingest "$home" "$fakebin" "$req")
  assert_contains "$out" "duplicate $req" "a re-delivered request must dedupe"
  # Same internetMessageId under another id: duplicate too.
  write_stash "$home/state/mail-inbox/20261010-1413-a3f9c1.json" 20261010-1413-a3f9c1 ".internetMessageId = \"<$req@example.com>\""
  out=$(ingest "$home" "$fakebin" 20261010-1413-a3f9c1)
  assert_contains "$out" "duplicate 20261010-1413-a3f9c1 (same message as $req)" "dedupe must use internetMessageId"
  # Wrong sender or tier: quarantined.
  write_stash "$home/state/mail-inbox/20261010-1414-bbbbbb.json" 20261010-1414-bbbbbb '.from = "attacker@example.org"'
  out=$(ingest "$home" "$fakebin" 20261010-1414-bbbbbb); expect_code 4 $? "untrusted sender exit"
  assert_contains "$out" "untrusted" "a non-captain sender must be quarantined"
  assert_present "$home/state/mail-inbox/untrusted/20261010-1414-bbbbbb.json" "quarantine keeps the stash aside"
  assert_absent "$home/data/mail-requests/20261010-1414-bbbbbb" "an untrusted request must not be ingested"
  write_stash "$home/state/mail-inbox/20261010-1415-cccccc.json" 20261010-1415-cccccc '.trust.authAs = "Anonymous"'
  ingest "$home" "$fakebin" 20261010-1415-cccccc >/dev/null; expect_code 4 $? "anonymous sender exit"
  # Oversized attachments: not downloaded.
  write_stash "$home/state/mail-inbox/20261010-1416-dddddd.json" 20261010-1416-dddddd '.attachments = [{"name":"huge.pdf","bytes":30000000}]'
  : > "$home/mail.log"
  out=$(ingest "$home" "$fakebin" 20261010-1416-dddddd); expect_code 3 $? "too-big exit"
  assert_contains "$out" "too-big 20261010-1416-dddddd" "oversized attachments must be reported"
  assert_no_grep "save-attachments" "$home/mail.log" "oversized attachments must not be downloaded"
  pass "fm-mail-ingest ingests, unzips, dedupes, quarantines, and caps attachments"
}

test_ingest_rechecks_saved_sizes() {
  local home fakebin out req=20261010-1420-eeeeee dir att
  home=$(make_home ingest-size); fakebin=$(make_fake_mail_axi "$home")
  mkdir -p "$home/state/mail-inbox"
  write_stash "$home/state/mail-inbox/$req.json" "$req" '.attachments = [{"id":"a1","name":"big.bin"},{"id":"a2","name":"x.txt","bytes":"lots"}]'
  att="$home/att"; mkdir -p "$att"
  head -c 2000 /dev/zero > "$att/big.bin"
  printf 'x' > "$att/x.txt"
  out=$(FM_MAIL_MAX_FILE_BYTES=1000 FAKE_ATTACH_SRC="$att" ingest "$home" "$fakebin" "$req"); expect_code 3 $? "saved over-cap exit"
  dir="$home/data/mail-requests/$req"
  assert_contains "$out" "too-big $req" "over-cap saved files must be reported too-big"
  assert_contains "$out" "deleted" "the report must say the downloads were deleted"
  [ -z "$(find "$dir/in" -mindepth 1 2>/dev/null)" ] || fail "over-cap downloads must be deleted"
  assert_present "$dir/.ingested" "a too-big request is still ingested"
  assert_absent "$home/state/mail-inbox/$req.json" "a too-big request drains the inbox"
  req=20261010-1421-ffffff
  write_stash "$home/state/mail-inbox/$req.json" "$req" '.attachments = [{"id":"a1","name":"big.bin","bytes":10},{"id":"a2","name":"x.txt","bytes":1}]'
  out=$(FM_MAIL_MAX_FILE_BYTES=5000 FM_MAIL_MAX_REQUEST_BYTES=1500 FAKE_ATTACH_SRC="$att" ingest "$home" "$fakebin" "$req"); expect_code 3 $? "saved over request cap exit"
  assert_contains "$out" "too-big $req" "under-declared files over the request cap must be too-big"
  pass "fm-mail-ingest re-checks real attachment sizes after download"
}

# --- reply, link, followup -------------------------------------------------

seed_request() {
  local home=$1 req=$2 dir
  dir="$home/data/mail-requests/$req"; mkdir -p "$dir/in" "$dir/out"
  write_stash "$dir/request.json" "$req"
  : > "$dir/.ingested"
}

test_reply_drafts_and_moves() {
  local home fakebin req=20261010-1412-a3f9c1 dir out rc
  home=$(make_home reply); fakebin=$(make_fake_mail_axi "$home")
  seed_request "$home" "$req"; dir="$home/data/mail-requests/$req"
  printf 'Done, captain.\n' > "$home/body.txt"
  printf 'q' > "$dir/out/quote.csv"
  printf 'secret' > "$home/.env.copy"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FAKE_MAIL_LOG="$home/mail.log" \
    "$ROOT/bin/fm-mail-reply.sh" "$req" --body-file "$home/body.txt" --attach "$dir/out/quote.csv" --done); expect_code 0 $? "reply exit"
  assert_contains "$out" "draft draft-123" "reply must print the draft id"
  assert_grep "reply-draft AAkALgAA-graph_id= --mailbox firstmate@example.com --body-file $home/body.txt --attach" "$home/mail.log" "reply must call reply-draft"
  assert_grep "move AAkALgAA-graph_id= --folder done --mailbox firstmate@example.com" "$home/mail.log" "--done must move the message"
  assert_grep "draft draft-123" "$dir/replies.log" "the draft id must be logged"
  PATH="$fakebin:$PATH" FM_HOME="$home" "$ROOT/bin/fm-mail-reply.sh" "$req" --body-file "$home/body.txt" --attach "$home/.env.copy" >/dev/null 2>&1
  expect_code 2 $? "attachments outside out/ must be refused"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FAKE_MOVE_FAIL=1 "$ROOT/bin/fm-mail-reply.sh" "$req" --body-file "$home/body.txt" --done 2>/dev/null); rc=$?
  expect_code 6 "$rc" "draft ok but move failed"
  PATH="$fakebin:$PATH" FM_HOME="$home" "$ROOT/bin/fm-mail-reply.sh" "../x" --done >/dev/null 2>&1; expect_code 2 $? "unsafe req"
  pass "fm-mail-reply drafts by file, restricts attachments to out/, and moves to done"
}

test_reply_send_mode() {
  local home fakebin req=20261010-1412-a3f9c1 dir out
  home=$(make_home send); fakebin=$(make_fake_mail_axi "$home")
  seed_request "$home" "$req"; dir="$home/data/mail-requests/$req"
  printf 'Done, captain.\n' > "$home/body.txt"
  printf 'q' > "$dir/out/quote.csv"
  PATH="$fakebin:$PATH" FM_HOME="$home" "$ROOT/bin/fm-mail-reply.sh" "$req" --body-file "$home/body.txt" --send >/dev/null 2>&1
  expect_code 2 $? "--send must be refused without FM_MAIL_SEND=1"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FAKE_MAIL_LOG="$home/mail.log" "$ROOT/bin/fm-mail-reply.sh" "$req" --body-file "$home/body.txt")
  assert_contains "$out" "draft draft-123" "draft stays the default without the opt-in"
  assert_no_grep "reply-send" "$home/mail.log" "no send without the opt-in"
  : > "$home/mail.log"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_MAIL_SEND=1 FAKE_MAIL_LOG="$home/mail.log" \
    "$ROOT/bin/fm-mail-reply.sh" "$req" --body-file "$home/body.txt" --attach "$dir/out/quote.csv" --done); expect_code 0 $? "send exit"
  assert_contains "$out" "send sent-456" "send must print the sent id"
  assert_grep "reply-send AAkALgAA-graph_id= --mailbox firstmate@example.com --body-file $home/body.txt --cc-captain --attach" "$home/mail.log" "send must call reply-send with --cc-captain"
  assert_grep "send sent-456" "$dir/replies.log" "the sent id must be logged"
  : > "$home/mail.log"
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_MAIL_SEND=1 FAKE_MAIL_LOG="$home/mail.log" "$ROOT/bin/fm-mail-reply.sh" "$req" --body-file "$home/body.txt" --draft >/dev/null
  assert_grep "reply-draft" "$home/mail.log" "--draft must force a draft"
  assert_no_grep "reply-send" "$home/mail.log" "--draft must not send"
  printf 'FM_MAIL_SEND=1\n' >> "$home/.env"
  : > "$home/mail.log"
  printf 'window=fm-t1\nkind=ship\n' > "$home/state/t1.meta"
  FM_HOME="$home" "$ROOT/bin/fm-mail-link.sh" t1 "$req" >/dev/null
  PATH="$fakebin:$PATH" FM_HOME="$home" FAKE_MAIL_LOG="$home/mail.log" "$ROOT/bin/fm-mail-followup.sh" t1 --final --body-file "$home/body.txt" >/dev/null
  expect_code 0 $? "send followup via .env opt-in"
  assert_grep "--cc-captain" "$home/mail.log" "follow-up must send with --cc-captain when opted in"
  pass "fm-mail-reply and fm-mail-followup send only when FM_MAIL_SEND=1, always with --cc-captain"
}

test_link_and_followup() {
  local home fakebin req=20261010-1412-a3f9c1 out
  home=$(make_home link); fakebin=$(make_fake_mail_axi "$home")
  seed_request "$home" "$req"
  printf 'window=fm-t1\nkind=ship\n' > "$home/state/t1.meta"
  "$ROOT/bin/fm-mail-followup.sh" --check t1 >/dev/null 2>&1; expect_code 1 $? "unlinked check"
  FM_HOME="$home" "$ROOT/bin/fm-mail-link.sh" t1 nosuch-req >/dev/null 2>&1; expect_code 1 $? "link to un-ingested request"
  FM_HOME="$home" "$ROOT/bin/fm-mail-link.sh" missing "$req" >/dev/null 2>&1; expect_code 1 $? "link to missing task"
  out=$(FM_HOME="$home" FM_MAIL_NOW_OVERRIDE=1700000000 "$ROOT/bin/fm-mail-link.sh" t1 "$req"); expect_code 0 $? "link exit"
  assert_grep "mail_req=$req" "$home/state/t1.meta" "link must record mail_req"
  assert_grep "mail_req_ts=1700000000" "$home/state/t1.meta" "link must record the time"
  assert_grep "window=fm-t1" "$home/state/t1.meta" "link must preserve other meta lines"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-mail-followup.sh" --check t1)
  [ "$out" = "$req" ] || fail "check must print the linked request (got: $out)"
  printf 'Progress.\n' > "$home/body.txt"
  PATH="$fakebin:$PATH" FM_HOME="$home" FAKE_REPLY_FAIL=1 "$ROOT/bin/fm-mail-followup.sh" t1 --body-file "$home/body.txt" >/dev/null 2>&1
  expect_code 1 $? "failed draft"
  assert_grep "mail_req=$req" "$home/state/t1.meta" "a failed draft must keep the link"
  PATH="$fakebin:$PATH" FM_HOME="$home" FAKE_MAIL_LOG="$home/mail.log" "$ROOT/bin/fm-mail-followup.sh" t1 --body-file "$home/body.txt" >/dev/null
  expect_code 0 $? "non-final followup"
  assert_grep "mail_req=$req" "$home/state/t1.meta" "a non-final follow-up must keep the link"
  assert_no_grep "move " "$home/mail.log" "a non-final follow-up must not move the message"
  PATH="$fakebin:$PATH" FM_HOME="$home" FAKE_MAIL_LOG="$home/mail.log" "$ROOT/bin/fm-mail-followup.sh" t1 --final --body-file "$home/body.txt" >/dev/null
  expect_code 0 $? "final followup"
  assert_no_grep "mail_req" "$home/state/t1.meta" "--final must clear the link"
  assert_grep "move AAkALgAA-graph_id= --folder done" "$home/mail.log" "--final must move the message to done"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$ROOT/bin/fm-mail-followup.sh" t1 --final --body-file "$home/body.txt" 2>&1)
  expect_code 0 $? "unlinked followup is a no-op"
  assert_contains "$out" "not mail-linked" "an unlinked follow-up must say so"
  if [ "$(id -u)" != 0 ]; then
    FM_HOME="$home" "$ROOT/bin/fm-mail-link.sh" t1 "$req" >/dev/null
    chmod 555 "$home/state"
    PATH="$fakebin:$PATH" FM_HOME="$home" "$ROOT/bin/fm-mail-followup.sh" t1 --final --body-file "$home/body.txt" >/dev/null 2>&1
    expect_code 7 $? "final drafted but link not cleared"
    chmod 755 "$home/state"
  fi
  pass "fm-mail-link and fm-mail-followup record, draft, and clear the link"
}

# --- prune -----------------------------------------------------------------

test_prune_retention() {
  local home root now out
  home="$TMP_ROOT/prune"; root="$home/data/mail-requests"
  mkdir -p "$home/state" "$root/20260101-0900-aaaaaa" "$root/20260101-0901-bbbbbb" "$root/20261001-0900-cccccc" "$root/notes"
  printf 'mail_req=20260101-0901-bbbbbb\n' > "$home/state/live.meta"
  now=$(date -u -d 2026-10-10 +%s 2>/dev/null || date -u -j -f %Y-%m-%d 2026-10-10 +%s)
  out=$(FM_HOME="$home" FM_MAIL_NOW_OVERRIDE="$now" "$ROOT/bin/fm-mail-prune.sh")
  assert_contains "$out" "pruned 20260101-0900-aaaaaa" "a request past retention must be pruned"
  assert_absent "$root/20260101-0900-aaaaaa" "the old folder must be gone"
  assert_present "$root/20260101-0901-bbbbbb" "a folder linked to a live task must be kept"
  assert_present "$root/20261001-0900-cccccc" "a recent folder must be kept"
  assert_present "$root/notes" "a non-request folder must never be touched"
  mkdir -p "$root/20260102-0900-dddddd"
  out=$(FM_HOME="$home" FM_MAIL_NOW_OVERRIDE="$((now + 60))" "$ROOT/bin/fm-mail-prune.sh" --if-due)
  [ -z "$out" ] || fail "--if-due must stay silent within 24h (got: $out)"
  assert_present "$root/20260102-0900-dddddd" "--if-due must skip within 24h"
  out=$(FM_HOME="$home" FM_MAIL_NOW_OVERRIDE="$((now + 90000))" "$ROOT/bin/fm-mail-prune.sh" --if-due)
  assert_contains "$out" "pruned 20260102-0900-dddddd" "--if-due must run once a day has passed"
  pass "fm-mail-prune keeps 90 days by request date, skips live-linked and non-request folders, and runs daily"
}

test_poll_inert_without_config
test_poll_empty_is_silent
test_poll_wake_line
test_poll_ignores_unsafe_or_unstashed_ids
test_poll_rewakes_for_stranded_stashes
test_poll_error_rate_limited
test_poll_timeout
test_bootstrap_opt_in_and_out
test_bootstrap_missing_mail_axi
test_supervision_instructions_source_mail_cadence
test_unzip_extracts_and_nests_one_level
test_unzip_limits
test_ingest_ok_duplicate_untrusted_toobig
test_ingest_rechecks_saved_sizes
test_reply_drafts_and_moves
test_reply_send_mode
test_link_and_followup
test_prune_retention
