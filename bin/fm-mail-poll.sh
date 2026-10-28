#!/usr/bin/env bash
# One bounded poll of the mail-mode intake mailbox through `mail-axi intake`.
#
# Inert by default: a HARD no-op (exit 0, no output) unless mail mode is
# configured via non-empty FM_MAIL_INTAKE and FM_MAIL_CAPTAIN (from the home's
# .env or the environment). This script is the body of the watcher check shim
# state/mail-watch.check.sh, where the contract is "output => wake firstmate,
# silence => keep sleeping".
#
# Behavior when mail mode is on:
#   mail-axi accepted nothing                -> print nothing, exit 0 (no wake)
#   mail-axi accepted one or more requests   -> mail-axi already stashed each as
#       state/mail-inbox/<req>.json; print one line "mail-request <req>" with a
#       " (+N)" suffix when N more were accepted in the same batch
#   nothing accepted, but stashes still wait in state/mail-inbox/ (an ingest
#       error, a restart mid-drain, a missed wake) -> the same "mail-request
#       <oldest> (+N)" line, repeated only when the pending set changes or
#       FM_MAIL_PENDING_REWAKE seconds (default 1800) have passed
#   missing tool/config (tenant, jq, mail tool, inbox)  -> one rate-limited
#       diagnostic line "mail-intake-error <msg>" at once; a bad or ambiguous
#       FM_MAIL_AXI resolution is a config error and surfaces at once too
#   nonzero exit, timeout, unparseable output, or reported errors with nothing
#       accepted (transient-prone)           -> counted, not surfaced, until
#       FM_MAIL_ERROR_THRESHOLD consecutive polls (default 2) have failed; then
#       the same "mail-intake-error <msg>" line. Homes sharing one mailbox flap
#       on isolated timeouts, so a lone failure never wakes firstmate; a clean
#       poll resets the count (state/mail-poll.failcount)
#   "mail-intake-error" is repeated only when the message changes or after a
#       clean poll clears it; whenever a failure is suppressed (below the
#       threshold or a repeat), the stranded-stash reminder above still fires,
#       so waiting requests resurface while mail-axi itself is failing
# Failure diagnostics: built from mail-axi stderr first, then stdout (a JSON
# error/message field, else the first non-empty line), sanitized and bounded;
# it carries mail-axi error text only. Every failure (also the suppressed ones)
# is appended as "epoch rc=<rc> elapsed=<s>s <msg>" to state/mail-poll.failures.log,
# trimmed to stay small, so contention between homes can be judged later.
# Sender verification (Gate 2) is mail-axi's job and happens before any stash;
# this script never reads message content. Request ids that are not safe slugs
# or have no stash file are ignored.
# Every run also triggers bin/fm-mail-prune.sh --if-due (silent, at most daily).
#
# Config (home .env, FM_MAIL_ENV_FILE, or env; the environment wins): FM_MAIL_INTAKE, FM_MAIL_CAPTAIN
# (comma-separated allowlist passed to --allow-from), FM_MAIL_TENANT (required
# once mail mode is on), FM_MAIL_AXI (absolute path to the mail tool; resolved
# fail-closed by fmm_resolve_axi in bin/fm-mail-lib.sh, never a bare PATH
# lookup when set). FM_MAIL_POLL_TIMEOUT (default 20s, also read from .env, kept below
# FM_CHECK_TIMEOUT) bounds the mail-axi call. FM_MAIL_PENDING_REWAKE (default
# 1800s) rate-limits the reminder wake for stashes left in the inbox.
# FM_MAIL_ERROR_THRESHOLD (default 2, also read from .env) is the consecutive-failure count that
# surfaces a transient-prone failure. FM_MAIL_STAGGER_MAX (default 5s, at most a
# quarter of FM_CHECK_TIMEOUT) bounds a deterministic per-home sleep
# (cksum of FM_HOME mod max+1) before the mail-axi call so homes polling one
# mailbox do not hit it in the same instant; the stagger plus the mail-axi
# timeout is clamped below FM_CHECK_TIMEOUT. There is no retry: the next poll,
# 60s later, is the retry.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-mail-lib.sh
. "$SCRIPT_DIR/fm-mail-lib.sh"

fmm_load_config
fmm_enabled || exit 0

"$SCRIPT_DIR/fm-mail-prune.sh" --if-due >/dev/null 2>&1 || true

ERROR_FILE="$STATE/mail-poll.error"
FAILCOUNT_FILE="$STATE/mail-poll.failcount"
FAILURE_LOG="$STATE/mail-poll.failures.log"
PENDING_FILE="$STATE/mail-poll.pending"
INBOX="$STATE/mail-inbox"

# Error text can echo mail-axi stderr, so keep it to one printable bounded line.
clean_line() {
  printf '%s' "$1" | tr '\r\n\t' '   ' | tr -cd '[:print:]' | cut -c1-200
}

emit_error_once() {
  local msg
  msg=$(clean_line "$1")
  mkdir -p "$STATE" 2>/dev/null || true
  if [ -f "$ERROR_FILE" ] && [ "$(cat "$ERROR_FILE" 2>/dev/null)" = "$msg" ]; then
    return 1
  fi
  printf '%s\n' "$msg" > "$ERROR_FILE" 2>/dev/null || true
  printf 'mail-intake-error %s\n' "$msg"
}

clear_error() {
  rm -f "$ERROR_FILE" "$FAILCOUNT_FILE" 2>/dev/null || true
}

# log_failure <rc> <elapsed> <msg>: bounded append-only record of every failure.
log_failure() {
  mkdir -p "$STATE" 2>/dev/null || true
  printf '%s rc=%s elapsed=%ss %s\n' "$NOW" "$1" "$2" "$(clean_line "$3")" >> "$FAILURE_LOG" 2>/dev/null || true
  if [ "$(wc -l < "$FAILURE_LOG" 2>/dev/null || echo 0)" -gt 400 ]; then
    if tail -n 200 "$FAILURE_LOG" > "$FAILURE_LOG.tmp" 2>/dev/null; then
      mv "$FAILURE_LOG.tmp" "$FAILURE_LOG" 2>/dev/null || true
    fi
  fi
}

# diag_text <stderr-file> <stdout-file>: stderr first, then a JSON error field or
# the first non-empty line of stdout (mail-axi --json may report errors there).
diag_text() {
  local t
  t=$(head -n1 "$1" 2>/dev/null)
  if [ -z "$t" ]; then
    t=$(jq -r 'if type == "object" then (.error // .message // empty | if type == "object" then (.message // tojson) else tostring end) else empty end' "$2" 2>/dev/null | head -n1)
  fi
  [ -n "$t" ] || t=$(grep -m1 '[^[:space:]]' "$2" 2>/dev/null)
  [ -n "$t" ] || t="no output"
  clean_line "$t"
}

pending_list() {
  local f req
  for f in "$INBOX"/*.json; do
    [ -f "$f" ] || continue
    req=$(basename "$f" .json)
    fmm_safe_slug "$req" && printf '%s\n' "$req"
  done | LC_ALL=C sort
}

# record_pending: remember the current pending set as already woken for.
record_pending() {
  local list
  list=$(pending_list)
  if [ -z "$list" ]; then
    rm -f "$PENDING_FILE" 2>/dev/null || true
    return 0
  fi
  printf '%s\n%s\n' "$NOW" "$list" > "$PENDING_FILE" 2>/dev/null || true
}

# wake_pending: print a reminder wake for stashes still in the inbox, at most
# once per distinct pending set per FM_MAIL_PENDING_REWAKE seconds.
wake_pending() {
  local list count first last rewake
  list=$(pending_list)
  if [ -z "$list" ]; then
    rm -f "$PENDING_FILE" 2>/dev/null || true
    return 1
  fi
  rewake=${FM_MAIL_PENDING_REWAKE:-1800}
  case "$rewake" in ''|*[!0-9]*) rewake=1800 ;; esac
  if [ -f "$PENDING_FILE" ] && [ "$(tail -n +2 "$PENDING_FILE" 2>/dev/null)" = "$list" ]; then
    last=$(head -n1 "$PENDING_FILE" 2>/dev/null)
    case "$last" in ''|*[!0-9]*) last=0 ;; esac
    [ $((NOW - last)) -ge "$rewake" ] || return 1
  fi
  printf '%s\n%s\n' "$NOW" "$list" > "$PENDING_FILE" 2>/dev/null || true
  first=$(printf '%s\n' "$list" | head -n1)
  count=$(printf '%s\n' "$list" | wc -l | tr -d ' ')
  if [ "$count" -gt 1 ]; then
    printf 'mail-request %s (+%s)\n' "$first" "$((count - 1))"
  else
    printf 'mail-request %s\n' "$first"
  fi
}

# fail_poll: report an early failure once, else remind about stranded stashes.
fail_poll() {
  log_failure - 0 "$1"
  emit_error_once "$1" || wake_pending
  exit 0
}

# transient_fail <rc> <elapsed> <msg>: log, count, and surface only once
# FM_MAIL_ERROR_THRESHOLD consecutive polls have failed.
transient_fail() {
  local n threshold
  log_failure "$1" "$2" "$3"
  threshold=${FMM_ERROR_THRESHOLD:-2}
  case "$threshold" in ''|*[!0-9]*) threshold=2 ;; esac
  n=$(cat "$FAILCOUNT_FILE" 2>/dev/null)
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  n=$((n + 1))
  printf '%s\n' "$n" > "$FAILCOUNT_FILE" 2>/dev/null || true
  if [ "$n" -ge "$threshold" ]; then
    emit_error_once "$3" || wake_pending
  else
    wake_pending
  fi
  exit 0
}

NOW=${FM_MAIL_NOW_OVERRIDE:-$(date +%s)}
case "$NOW" in ''|*[!0-9]*) NOW=$(date +%s) ;; esac

[ -n "$FMM_TENANT" ] || fail_poll "missing FM_MAIL_TENANT"
command -v jq >/dev/null 2>&1 || fail_poll "missing jq"
fmm_resolve_axi || fail_poll "$FMM_AXI_ERROR"
mkdir -p "$INBOX" 2>/dev/null || fail_poll "cannot create inbox"

limit=${FMM_POLL_TIMEOUT:-20}
case "$limit" in ''|*[!0-9]*) limit=20 ;; esac
check_limit=${FM_CHECK_TIMEOUT:-30}
case "$check_limit" in ''|*[!0-9]*) check_limit=30 ;; esac
stagger_max=${FM_MAIL_STAGGER_MAX:-5}
case "$stagger_max" in ''|*[!0-9]*) stagger_max=5 ;; esac
[ "$stagger_max" -le $((check_limit / 4)) ] || stagger_max=$((check_limit / 4))
stagger=$(( $(printf '%s' "$FM_HOME" | cksum | cut -d' ' -f1) % (stagger_max + 1) ))
if [ $((stagger + limit + 5)) -gt "$check_limit" ]; then
  limit=$((check_limit - stagger - 5))
  [ "$limit" -ge 1 ] || limit=1
fi

OUT=$(mktemp "${TMPDIR:-/tmp}/fm-mail-poll.out.XXXXXX") || exit 0
ERR=$(mktemp "${TMPDIR:-/tmp}/fm-mail-poll.err.XXXXXX") || { rm -f "$OUT"; exit 0; }
trap 'rm -f "$OUT" "$ERR"' EXIT

[ "$stagger" -le 0 ] || sleep "$stagger"
started=$(date +%s)
set -- "$FMM_AXI" intake --mailbox "$FMM_INTAKE" --stash-dir "$INBOX" \
  --allow-from "${FMM_CAPTAIN// /}" --tenant "$FMM_TENANT" --json
if command -v timeout >/dev/null 2>&1; then
  timeout "$limit" "$@" > "$OUT" 2> "$ERR"
else
  "$@" > "$OUT" 2> "$ERR"
fi
rc=$?
elapsed=$(($(date +%s) - started))

if [ "$rc" -eq 124 ]; then
  transient_fail "$rc" "$elapsed" "mail-axi intake timed out after ${limit}s"
fi
if [ "$rc" -ne 0 ]; then
  transient_fail "$rc" "$elapsed" "mail-axi intake failed (exit $rc): $(diag_text "$ERR" "$OUT")"
fi

if ! jq -e 'type == "object" and ((.accepted // []) | type) == "array"' "$OUT" >/dev/null 2>&1; then
  transient_fail 0 "$elapsed" "mail-axi intake returned unparseable output"
fi

first=
count=0
while IFS= read -r req; do
  fmm_safe_slug "$req" || continue
  [ -f "$INBOX/$req.json" ] || continue
  [ -n "$first" ] || first=$req
  count=$((count + 1))
done < <(jq -r '(.accepted // [])[] | strings' "$OUT" 2>/dev/null)

if [ "$count" -gt 0 ]; then
  clear_error
  record_pending
  if [ "$count" -gt 1 ]; then
    printf 'mail-request %s (+%s)\n' "$first" "$((count - 1))"
  else
    printf 'mail-request %s\n' "$first"
  fi
  exit 0
fi

nerr=$(jq -r '(.errors // []) | length' "$OUT" 2>/dev/null || echo 0)
case "$nerr" in ''|*[!0-9]*) nerr=0 ;; esac
if [ "$nerr" -gt 0 ]; then
  transient_fail 0 "$elapsed" "mail-axi intake reported $nerr error(s): $(jq -r '(.errors[0] | if type == "string" then . else tojson end)' "$OUT" 2>/dev/null)"
fi

wake_pending && exit 0
clear_error
