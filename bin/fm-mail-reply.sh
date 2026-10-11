#!/usr/bin/env bash
# Create a threaded reply to a mail-mode request (DRAFT by default, SENT when
# opted in), and/or file the original message in the "done" folder.
#
# Usage: fm-mail-reply.sh <req> --body-file <path> [--attach <file>]... [--send|--draft] [--done]
#        fm-mail-reply.sh <req> --done
#   Reads the Graph id from data/mail-requests/<req>/request.json (written by
#   bin/fm-mail-ingest.sh) and runs
#     mail-axi reply-draft <graphId> --mailbox <FM_MAIL_INTAKE> --body-file <path> [--attach <file>]...
#   which creates a reply draft in the intake mailbox's Drafts, threaded to the
#   original and addressed by Exchange to its verified sender. No address is ever
#   taken from mail content.
#   Send mode: with FM_MAIL_SEND=1 in .env (or the environment) the reply is SENT
#   instead, via `mail-axi reply-send <graphId> --mailbox ... --body-file <path>
#   --cc-captain --allow-from <FM_MAIL_CAPTAIN> [--attach <file>]...`. mail-axi enforces the recipient allowlist
#   (exactly the FM_MAIL_CAPTAIN addresses, the first address cc'd on every
#   message) in code; the tenant admin script (phase2-send) must have been run
#   first. --send requests send mode explicitly and is refused unless
#   FM_MAIL_SEND=1; --draft forces a draft even when send is opted in.
#   Each draft/sent id is appended to data/mail-requests/<req>/replies.log and printed.
#   --attach paths must resolve inside data/mail-requests/<req>/out/, so a reply
#   can never carry an arbitrary local file; copy deliverables there first.
#   --done then runs `mail-axi move <graphId> --folder done --mailbox ...`.
#
# The body is always passed by file: never inline mail-influenced text into a
# shell command.
# Exit: 0 success; 1 draft/send or move failed; 2 usage/unsafe input or mail mode
# off; 6 draft created but the --done move failed (retry with: <req> --done).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
# shellcheck source=bin/fm-mail-lib.sh
. "$SCRIPT_DIR/fm-mail-lib.sh"

usage() {
  echo "usage: fm-mail-reply.sh <req> --body-file <path> [--attach <file>]... [--send|--draft] [--done] | <req> --done" >&2
}

REQ=${1:-}
[ -n "$REQ" ] || { usage; exit 2; }
case "$REQ" in -h|--help) sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;; esac
shift
fmm_safe_slug "$REQ" || { echo "fm-mail-reply: unsafe request id: $REQ" >&2; exit 2; }

BODY=
DONE=0
WANT=
ATTACH=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --body-file) [ "$#" -ge 2 ] || { usage; exit 2; }; BODY=$2; shift 2 ;;
    --attach) [ "$#" -ge 2 ] || { usage; exit 2; }; ATTACH+=("$2"); shift 2 ;;
    --send) WANT=send; shift ;;
    --draft) WANT=draft; shift ;;
    --done) DONE=1; shift ;;
    *) usage; exit 2 ;;
  esac
done
if [ -z "$BODY" ] && { [ "$DONE" -eq 0 ] || [ "${#ATTACH[@]}" -gt 0 ]; }; then
  usage; exit 2
fi

fmm_load_config
fmm_enabled || { echo "fm-mail-reply: mail mode is off" >&2; exit 2; }
MODE=draft
if [ "$WANT" = send ] && ! fmm_send_enabled; then
  echo "fm-mail-reply: --send requires FM_MAIL_SEND=1 (real sends are not enabled)" >&2
  exit 2
fi
if [ "$WANT" != draft ] && fmm_send_enabled; then MODE=send; fi
command -v jq >/dev/null 2>&1 || { echo "fm-mail-reply: jq not found" >&2; exit 1; }
command -v mail-axi >/dev/null 2>&1 || { echo "fm-mail-reply: mail-axi not found" >&2; exit 1; }

DIR=$(fmm_request_dir "$REQ")
[ -f "$DIR/request.json" ] || { echo "fm-mail-reply: no ingested request $REQ" >&2; exit 2; }
GRAPH_ID=$(jq -r '.graphId // ""' "$DIR/request.json")
case "$GRAPH_ID" in
  ''|-*|*[!A-Za-z0-9+/=_-]*) echo "fm-mail-reply: malformed graphId in $REQ" >&2; exit 2 ;;
esac

if [ -n "$BODY" ]; then
  if [ ! -s "$BODY" ] || ! grep -q '[^[:space:]]' "$BODY"; then
    echo "fm-mail-reply: empty reply body" >&2
    exit 2
  fi
  out_real=$(cd "$DIR/out" 2>/dev/null && pwd -P) || { echo "fm-mail-reply: missing $DIR/out" >&2; exit 2; }
  if [ "$MODE" = send ]; then
    args=(reply-send "$GRAPH_ID" --mailbox "$FMM_INTAKE" --body-file "$BODY" --cc-captain --allow-from "$FMM_CAPTAIN")
  else
    args=(reply-draft "$GRAPH_ID" --mailbox "$FMM_INTAKE" --body-file "$BODY")
  fi
  for f in ${ATTACH[@]+"${ATTACH[@]}"}; do
    if [ ! -f "$f" ] || [ -L "$f" ]; then
      echo "fm-mail-reply: not a regular file: $f" >&2
      exit 2
    fi
    real="$(cd "$(dirname "$f")" && pwd -P)/$(basename "$f")"
    case "$real" in
      "$out_real"/*) args+=(--attach "$real") ;;
      *) echo "fm-mail-reply: attachments must live under $DIR/out/: $f" >&2; exit 2 ;;
    esac
  done
  draft=$(mail-axi "${args[@]}" 2>/dev/null) || { echo "fm-mail-reply: mail-axi ${args[0]} failed for $REQ" >&2; exit 1; }
  draft=$(printf '%s' "$draft" | tr -d '\r' | tail -n1 | tr -cd '[:print:]' | cut -c1-300)
  printf '%s %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$MODE" "$draft" >> "$DIR/replies.log" 2>/dev/null || true
  printf '%s %s\n' "$MODE" "$draft"
fi

if [ "$DONE" -eq 1 ]; then
  if ! mail-axi move "$GRAPH_ID" --folder "done" --mailbox "$FMM_INTAKE" >/dev/null 2>&1; then
    echo "fm-mail-reply: could not move $REQ to done; retry with: fm-mail-reply.sh $REQ --done" >&2
    [ -n "$BODY" ] && exit 6
    exit 1
  fi
  printf '%s done\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$DIR/replies.log" 2>/dev/null || true
  printf 'moved %s to done\n' "$REQ"
fi
exit 0
