#!/usr/bin/env bash
# Write a follow-up reply (draft, or sent with FM_MAIL_SEND=1) for a mail-mode-linked task.
#
# A mail request that spawned real work is linked to its task by
# bin/fm-mail-link.sh (mail_req= in state/<id>.meta). On a milestone worth
# reporting, and always on the task's terminal wake, firstmate composes the
# reply to a file and drafts it here.
#
# Detection:
#   fm-mail-followup.sh --check <task-id>
#     exit 0, prints <req>  -> linked; a follow-up can be drafted
#     exit 1, silent        -> not linked
#
# Draft:
#   fm-mail-followup.sh <task-id> [--final] [--send|--draft] [--html|--text] [--attach <file>]... --body-file <path>
#     Calls bin/fm-mail-reply.sh <req> (attachments must sit in the request's
#     out/ folder). A non-final draft keeps the link. --final also moves the
#     original message to "done" and clears the link after the draft lands,
#     even when only that move failed (exit 6, retry the move with
#     `fm-mail-reply.sh <req> --done`), so a final reply is never drafted twice.
#     A failed draft or send leaves the link in place (exit 1); a failed send
#     may still have gone out, so check replies.log and Sent Items before retrying.
#     Exit 2 means fm-mail-reply.sh refused the request (bad input, mail mode
#     off, or --send without FM_MAIL_SEND=1); nothing was drafted or sent.
#     Exit 7 means the final draft landed but the link could not be cleared
#     from the task meta: do NOT retry the draft; remove the mail_req= and
#     mail_req_ts= lines from state/<id>.meta instead.
#     Not linked: nothing to do, exit 0.
#   --send / --draft are passed through to fm-mail-reply.sh (send needs
#   FM_MAIL_SEND=1, which also makes send the default; --draft forces a draft).
#   --html / --text are passed through too; replies default to HTML (see
#   fm-mail-reply.sh for the format default and FM_MAIL_HTML).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-mail-lib.sh
. "$SCRIPT_DIR/fm-mail-lib.sh"

usage() {
  echo "usage: fm-mail-followup.sh --check <task-id> | <task-id> [--final] [--send|--draft] [--html|--text] [--attach <file>]... --body-file <path>" >&2
}

case "${1:-}" in
  -h|--help) sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac

MODE=post
FINAL=0
REPLY_ARGS=()
if [ "${1:-}" = --check ]; then
  MODE=check
  ID=${2:-}
  if [ -z "$ID" ] || [ "$#" -ne 2 ]; then usage; exit 2; fi
else
  ID=${1:-}
  [ -n "$ID" ] || { usage; exit 2; }
  shift
  have_body=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --final) FINAL=1; shift ;;
      --send|--draft|--html|--text) REPLY_ARGS+=("$1"); shift ;;
      --body-file|--attach)
        [ "$#" -ge 2 ] || { usage; exit 2; }
        [ "$1" = --body-file ] && have_body=1
        REPLY_ARGS+=("$1" "$2"); shift 2 ;;
      *) usage; exit 2 ;;
    esac
  done
  [ "$have_body" -eq 1 ] || { usage; exit 2; }
fi
fmm_safe_slug "$ID" || { echo "fm-mail-followup: unsafe task id: $ID" >&2; exit 2; }

META="$STATE/$ID.meta"
REQ=$(fmx_meta_get "$META" mail_req)
if [ -z "$REQ" ]; then
  [ "$MODE" = check ] && exit 1
  echo "fm-mail-followup: $ID is not mail-linked; nothing to draft" >&2
  exit 0
fi
if [ "$MODE" = check ]; then
  printf '%s\n' "$REQ"
  exit 0
fi

[ "$FINAL" -eq 1 ] && REPLY_ARGS+=(--done)
"$SCRIPT_DIR/fm-mail-reply.sh" "$REQ" "${REPLY_ARGS[@]}"
rc=$?
case "$rc" in
  0|6)
    if [ "$FINAL" -eq 1 ]; then
      fmm_meta_link_clear "$META" || { echo "fm-mail-followup: drafted but could not clear the link in state/$ID.meta; do not retry the draft" >&2; exit 7; }
    fi
    exit "$rc"
    ;;
  2)
    echo "fm-mail-followup: reply refused for $ID (see above); nothing was drafted or sent, link left in place" >&2
    exit 2
    ;;
  *)
    echo "fm-mail-followup: reply failed for $ID; link left in place. A failed send may still have gone out: check data/mail-requests/$REQ/replies.log and the intake mailbox's Sent Items before retrying" >&2
    exit 1
    ;;
esac
