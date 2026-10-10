#!/usr/bin/env bash
# Link a spawned task to the mail-mode request that triggered it, so firstmate
# writes the final draft reply with results when the task lands.
#
# Usage: fm-mail-link.sh <task-id> <req>
#   Records in state/<task-id>.meta (replacing any prior mail link, preserving
#   every other meta line):
#     mail_req=<req>        the request folder data/mail-requests/<req>/
#     mail_req_ts=<epoch>   link time
#   The request must already be ingested (bin/fm-mail-ingest.sh). Relinking the
#   same request onto a successor task is the same call with the new task id.
#   The follow-up itself is owned by bin/fm-mail-followup.sh.
# FM_MAIL_NOW_OVERRIDE pins the link time for deterministic tests.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-mail-lib.sh
. "$SCRIPT_DIR/fm-mail-lib.sh"

ID=${1:-}
REQ=${2:-}
if [ "$#" -ne 2 ] || [ -z "$ID" ] || [ -z "$REQ" ]; then
  echo "usage: fm-mail-link.sh <task-id> <req>" >&2
  exit 2
fi
fmm_safe_slug "$ID" || { echo "fm-mail-link: unsafe task id: $ID" >&2; exit 2; }
fmm_safe_slug "$REQ" || { echo "fm-mail-link: unsafe request id: $REQ" >&2; exit 2; }

META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "fm-mail-link: no such task: state/$ID.meta" >&2; exit 1; }
[ -f "$(fmm_request_dir "$REQ")/request.json" ] || { echo "fm-mail-link: request $REQ is not ingested" >&2; exit 1; }

NOW=${FM_MAIL_NOW_OVERRIDE:-$(date +%s)}
case "$NOW" in ''|*[!0-9]*) echo "fm-mail-link: could not read the current time" >&2; exit 1 ;; esac

fmm_meta_link_set "$META" "$REQ" "$NOW" || { echo "fm-mail-link: failed to record the link in state/$ID.meta" >&2; exit 1; }
printf 'linked %s to mail request %s\n' "$ID" "$REQ"
