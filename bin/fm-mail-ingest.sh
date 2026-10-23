#!/usr/bin/env bash
# Ingest one stashed mail-mode request into its durable request folder.
#
# Usage: fm-mail-ingest.sh <req>
#   Reads state/mail-inbox/<req>.json (written by `mail-axi intake`) and turns it
#   into data/mail-requests/<req>/:
#     request.json      the stash, verbatim (ids, sender, trust evidence, text)
#     instruction.txt   the captain's new words only (mail-axi's uniqueBody)
#     in/               original attachments via `mail-axi save-attachments`
#     in/unzipped/<zip>/  each .zip extracted with bin/fm-mail-unzip.sh limits
#     out/              empty; results to attach to replies go here
#   then removes the inbox file. The request folder is complete only once its
#   .ingested marker exists, so a re-run after a failed save resumes safely.
#   `mail-axi` means the tool FM_MAIL_AXI resolves to, fail closed (fmm_resolve_axi).
#
# Defense in depth on top of mail-axi's Gate 2: the stash must name this <req>,
# carry trust.tier T1 and trust.authAs Internal, have a sender in the
# FM_MAIL_CAPTAIN allowlist, and a Graph id of safe characters. Anything else is
# moved to state/mail-inbox/untrusted/ and never ingested.
#
# Attachment caps: FM_MAIL_MAX_FILE_BYTES (default 25 MiB) per file and
# FM_MAIL_MAX_REQUEST_BYTES (default 50 MiB) per request. The stash's declared
# sizes are checked before download (over the cap, nothing is downloaded); a
# missing or non-numeric declared size counts as unknown, so the saved files'
# real sizes are re-checked after download and an over-cap request has its
# downloaded files deleted before reporting too-big.
#
# First output line and exit code:
#   ok <req>             0  ingested; following lines name the paths and results
#   duplicate <req> ...  0  already ingested (same req or internetMessageId);
#                           inbox file dropped, nothing else done
#   too-big <req> ...    3  ingested without attachments; reply asking for a link
#   untrusted <req> ...  4  stash failed verification; quarantined, do not act
#   error ...            1  mail-axi or filesystem failure; inbox file kept
# Exit 2 is a usage error or mail mode being off.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-mail-lib.sh
. "$SCRIPT_DIR/fm-mail-lib.sh"

REQ=${1:-}
if [ "$#" -ne 1 ] || ! fmm_safe_slug "$REQ"; then
  echo "usage: fm-mail-ingest.sh <req>   (req must be a safe slug)" >&2
  exit 2
fi
fmm_load_config
fmm_enabled || { echo "fm-mail-ingest: mail mode is off" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "error jq not found"; exit 1; }

INBOX_FILE="$STATE/mail-inbox/$REQ.json"
DIR=$(fmm_request_dir "$REQ")
REQ_ROOT=${DIR%/*}

if [ -f "$DIR/.ingested" ]; then
  rm -f "$INBOX_FILE"
  echo "duplicate $REQ (already ingested)"
  exit 0
fi
[ -f "$INBOX_FILE" ] || [ -f "$DIR/request.json" ] || { echo "error no stash for $REQ"; exit 1; }
SRC=$INBOX_FILE
[ -f "$SRC" ] || SRC="$DIR/request.json"

quarantine() {
  mkdir -p "$STATE/mail-inbox/untrusted" 2>/dev/null
  [ "$SRC" = "$INBOX_FILE" ] && mv -f "$INBOX_FILE" "$STATE/mail-inbox/untrusted/$REQ.json" 2>/dev/null
  echo "untrusted $REQ: $1"
  exit 4
}

jq -e 'type == "object"' "$SRC" >/dev/null 2>&1 || quarantine "unparseable stash"
[ "$(jq -r '.req // ""' "$SRC")" = "$REQ" ] || quarantine "stash names a different request"
[ "$(jq -r '.trust.tier // ""' "$SRC")" = T1 ] || quarantine "trust tier is not T1"
[ "$(jq -r '.trust.authAs // ""' "$SRC")" = Internal ] || quarantine "sender was not authenticated as Internal"
from=$(jq -r '.from // "" | ascii_downcase' "$SRC")
allowed=0
IFS=',' read -r -a captains <<< "$FMM_CAPTAIN"
for addr in "${captains[@]}"; do
  addr=$(printf '%s' "$addr" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
  [ -n "$addr" ] && [ "$addr" = "$from" ] && allowed=1
done
[ "$allowed" = 1 ] || quarantine "sender is not in FM_MAIL_CAPTAIN"
GRAPH_ID=$(jq -r '.graphId // ""' "$SRC")
case "$GRAPH_ID" in
  ''|-*|*[!A-Za-z0-9+/=_-]*) quarantine "missing or malformed graphId" ;;
esac

# Dedupe on internetMessageId: mail-axi is at-least-once.
MSG_ID=$(jq -r '.internetMessageId // ""' "$SRC")
if [ -n "$MSG_ID" ] && [ -d "$REQ_ROOT" ]; then
  for other in "$REQ_ROOT"/*/request.json; do
    [ -f "$other" ] || continue
    [ "$other" = "$DIR/request.json" ] && continue
    if [ "$(jq -r '.internetMessageId // ""' "$other" 2>/dev/null)" = "$MSG_ID" ]; then
      rm -f "$INBOX_FILE"
      echo "duplicate $REQ (same message as $(basename "$(dirname "$other")"))"
      exit 0
    fi
  done
fi

umask 077
mkdir -p "$DIR/in" "$DIR/out" || { echo "error cannot create $DIR"; exit 1; }
if [ "$SRC" = "$INBOX_FILE" ]; then
  if ! { cp "$INBOX_FILE" "$DIR/request.json.tmp" && mv -f "$DIR/request.json.tmp" "$DIR/request.json"; }; then
    echo "error cannot write $DIR/request.json"
    exit 1
  fi
fi
jq -r '.instruction // ""' "$DIR/request.json" > "$DIR/instruction.txt" || { echo "error cannot write instruction.txt"; exit 1; }

MAX_FILE=${FM_MAIL_MAX_FILE_BYTES:-26214400}
MAX_REQ=${FM_MAIL_MAX_REQUEST_BYTES:-52428800}
case "$MAX_FILE" in ''|*[!0-9]*) MAX_FILE=26214400 ;; esac
case "$MAX_REQ" in ''|*[!0-9]*) MAX_REQ=52428800 ;; esac
n_att=$(jq -r '(.attachments // []) | length' "$DIR/request.json")
largest=$(jq -r '[(.attachments // [])[] | ((.bytes // 0) | tonumber? // 0 | floor)] | max // 0' "$DIR/request.json")
total=$(jq -r '[(.attachments // [])[] | ((.bytes // 0) | tonumber? // 0 | floor)] | add // 0' "$DIR/request.json")

finish() {
  : > "$DIR/.ingested"
  rm -f "$INBOX_FILE"
}

too_big() {
  finish
  echo "too-big $REQ: $n_att attachment(s), $1 bytes (caps: $MAX_FILE per file, $MAX_REQ per request); $2"
  echo "dir: $DIR"
  echo "instruction: $DIR/instruction.txt"
  exit 3
}

if [ "$largest" -gt "$MAX_FILE" ] || [ "$total" -gt "$MAX_REQ" ]; then
  too_big "$total" "none downloaded"
fi

unzip_lines=()
if [ "$n_att" -gt 0 ]; then
  fmm_resolve_axi || { echo "error $FMM_AXI_ERROR"; exit 1; }
  if ! "$FMM_AXI" save-attachments "$GRAPH_ID" --dir "$DIR/in" --mailbox "$FMM_INTAKE" >/dev/null 2>"$DIR/.save.err"; then
    echo "error mail-axi save-attachments failed: $(head -n1 "$DIR/.save.err" | tr -cd '[:print:]' | cut -c1-200)"
    exit 1
  fi
  rm -f "$DIR/.save.err"
  saved_largest=0
  saved_total=0
  while IFS= read -r -d '' f; do
    size=$(wc -c < "$f" 2>/dev/null | tr -d ' ')
    case "$size" in ''|*[!0-9]*) size=$((MAX_FILE + 1)) ;; esac
    [ "$size" -gt "$saved_largest" ] && saved_largest=$size
    saved_total=$((saved_total + size))
  done < <(find "$DIR/in" -path "$DIR/in/unzipped" -prune -o -type f -print0)
  if [ "$saved_largest" -gt "$MAX_FILE" ] || [ "$saved_total" -gt "$MAX_REQ" ]; then
    find "$DIR/in" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null
    too_big "$saved_total" "downloaded files exceeded the caps and were deleted"
  fi
  for zip in "$DIR"/in/*; do
    [ -f "$zip" ] || continue
    case "$(printf '%s' "$zip" | tr '[:upper:]' '[:lower:]')" in *.zip) ;; *) continue ;; esac
    name=$(basename "$zip")
    target="$DIR/in/unzipped/$name"
    if [ -e "$target" ]; then
      unzip_lines+=("unzipped $name: already extracted")
      continue
    fi
    mkdir -p "$DIR/in/unzipped"
    result=$("$SCRIPT_DIR/fm-mail-unzip.sh" "$zip" "$target" 2>/dev/null)
    if [ "$(printf '%s' "$result" | jq -r '.ok // false' 2>/dev/null)" = true ]; then
      unzip_lines+=("unzipped $name: $(printf '%s' "$result" | jq -r '"\(.files) file(s)" + (if (.skipped | length) > 0 then ", skipped \(.skipped | length) nested archive(s)" else "" end)')")
    else
      unzip_lines+=("unzipped $name: refused: $(printf '%s' "$result" | jq -r '.reason // "unknown error"' 2>/dev/null)")
    fi
  done
fi

finish
echo "ok $REQ"
echo "dir: $DIR"
echo "instruction: $DIR/instruction.txt"
echo "attachments: $n_att saved to $DIR/in"
for line in ${unzip_lines[@]+"${unzip_lines[@]}"}; do
  echo "$line"
done
exit 0
