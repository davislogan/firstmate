#!/usr/bin/env bash
# Retention prune for mail-mode request folders (data/mail-requests/<req>/).
#
# Usage: fm-mail-prune.sh [--if-due]
#   Deletes request folders older than FM_MAIL_RETENTION_DAYS (default 90).
#   Age comes from the request id's YYYYMMDD prefix (mail-axi's req id format
#   YYYYMMDD-HHMM-<hex>), never from mtimes, so touching a file does not extend
#   retention. Folders whose name does not start with an 8-digit date are never
#   touched, and a folder still linked from a live state/<id>.meta (mail_req=)
#   is kept until that task is torn down.
#   Prints one "pruned <req>" line per deleted folder.
#   --if-due runs at most once per 24h (marker state/.mail-prune-last), which is
#   how bin/fm-mail-poll.sh calls it every poll cheaply.
# FM_MAIL_NOW_OVERRIDE pins "now" (epoch seconds) for deterministic tests.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
REQ_ROOT="$DATA/mail-requests"

IF_DUE=0
case "${1:-}" in
  '') ;;
  --if-due) IF_DUE=1 ;;
  -h|--help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) echo "usage: fm-mail-prune.sh [--if-due]" >&2; exit 2 ;;
esac

NOW=${FM_MAIL_NOW_OVERRIDE:-$(date +%s)}
case "$NOW" in ''|*[!0-9]*) echo "fm-mail-prune: could not read the current time" >&2; exit 1 ;; esac
DAYS=${FM_MAIL_RETENTION_DAYS:-90}
case "$DAYS" in ''|*[!0-9]*) DAYS=90 ;; esac

MARKER="$STATE/.mail-prune-last"
if [ "$IF_DUE" -eq 1 ] && [ -f "$MARKER" ]; then
  last=$(cat "$MARKER" 2>/dev/null)
  case "$last" in
    ''|*[!0-9]*) ;;
    *) [ "$((NOW - last))" -ge 86400 ] || exit 0 ;;
  esac
fi

cutoff_epoch=$((NOW - DAYS * 86400))
cutoff=$(date -u -d "@$cutoff_epoch" +%Y%m%d 2>/dev/null || date -u -r "$cutoff_epoch" +%Y%m%d 2>/dev/null) || {
  echo "fm-mail-prune: could not compute the retention cutoff" >&2
  exit 1
}

if [ -d "$REQ_ROOT" ]; then
  for dir in "$REQ_ROOT"/*/; do
    [ -d "$dir" ] || continue
    req=$(basename "$dir")
    day=${req%%-*}
    case "$day" in
      [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]) ;;
      *) continue ;;
    esac
    [ "$day" -lt "$cutoff" ] || continue
    if grep -qsxF "mail_req=$req" "$STATE"/*.meta; then
      continue
    fi
    rm -rf -- "${dir%/}" && printf 'pruned %s\n' "$req"
  done
fi

if mkdir -p "$STATE" 2>/dev/null; then
  printf '%s\n' "$NOW" > "$MARKER" 2>/dev/null || true
fi
exit 0
