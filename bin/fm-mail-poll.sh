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
#   missing tool/config, nonzero exit, timeout, unparseable output, or reported
#       errors with nothing accepted         -> one rate-limited diagnostic line
#       "mail-intake-error <msg>", repeated only when the message changes or
#       after a clean poll clears it; when that line is suppressed as a
#       repeat, the stranded-stash reminder above still fires, so waiting
#       requests resurface while mail-axi itself is failing
# Sender verification (Gate 2) is mail-axi's job and happens before any stash;
# this script never reads message content. Request ids that are not safe slugs
# or have no stash file are ignored.
# Every run also triggers bin/fm-mail-prune.sh --if-due (silent, at most daily).
#
# Config (home .env, FM_MAIL_ENV_FILE, or env): FM_MAIL_INTAKE, FM_MAIL_CAPTAIN
# (comma-separated allowlist passed to --allow-from), FM_MAIL_TENANT (required
# once mail mode is on). FM_MAIL_POLL_TIMEOUT (default 20s, kept below
# FM_CHECK_TIMEOUT) bounds the mail-axi call. FM_MAIL_PENDING_REWAKE (default
# 1800s) rate-limits the reminder wake for stashes left in the inbox.
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
  rm -f "$ERROR_FILE" 2>/dev/null || true
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
  emit_error_once "$1" || wake_pending
  exit 0
}

NOW=${FM_MAIL_NOW_OVERRIDE:-$(date +%s)}
case "$NOW" in ''|*[!0-9]*) NOW=$(date +%s) ;; esac

[ -n "$FMM_TENANT" ] || fail_poll "missing FM_MAIL_TENANT"
command -v jq >/dev/null 2>&1 || fail_poll "missing jq"
command -v mail-axi >/dev/null 2>&1 || fail_poll "missing mail-axi"
mkdir -p "$INBOX" 2>/dev/null || fail_poll "cannot create inbox"

limit=${FM_MAIL_POLL_TIMEOUT:-20}
case "$limit" in ''|*[!0-9]*) limit=20 ;; esac
check_limit=${FM_CHECK_TIMEOUT:-30}
case "$check_limit" in ''|*[!0-9]*) check_limit=30 ;; esac
if [ "$limit" -ge "$check_limit" ]; then
  limit=$((check_limit - 5))
  [ "$limit" -ge 1 ] || limit=1
fi

OUT=$(mktemp "${TMPDIR:-/tmp}/fm-mail-poll.out.XXXXXX") || exit 0
ERR=$(mktemp "${TMPDIR:-/tmp}/fm-mail-poll.err.XXXXXX") || { rm -f "$OUT"; exit 0; }
trap 'rm -f "$OUT" "$ERR"' EXIT

set -- mail-axi intake --mailbox "$FMM_INTAKE" --stash-dir "$INBOX" \
  --allow-from "${FMM_CAPTAIN// /}" --tenant "$FMM_TENANT" --json
if command -v timeout >/dev/null 2>&1; then
  timeout "$limit" "$@" > "$OUT" 2> "$ERR"
else
  "$@" > "$OUT" 2> "$ERR"
fi
rc=$?

if [ "$rc" -eq 124 ]; then
  fail_poll "mail-axi intake timed out after ${limit}s"
fi
if [ "$rc" -ne 0 ]; then
  fail_poll "mail-axi intake failed (exit $rc): $(head -n1 "$ERR" 2>/dev/null)"
fi

if ! jq -e 'type == "object" and ((.accepted // []) | type) == "array"' "$OUT" >/dev/null 2>&1; then
  fail_poll "mail-axi intake returned unparseable output"
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

wake_pending && exit 0

nerr=$(jq -r '(.errors // []) | length' "$OUT" 2>/dev/null || echo 0)
case "$nerr" in ''|*[!0-9]*) nerr=0 ;; esac
if [ "$nerr" -gt 0 ]; then
  emit_error_once "mail-axi intake reported $nerr error(s): $(jq -r '(.errors[0] | if type == "string" then . else tojson end)' "$OUT" 2>/dev/null)"
  exit 0
fi
clear_error
