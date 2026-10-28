#!/usr/bin/env bash
# fm-marker-lib.sh - the from-firstmate request marker.
#
# When the MAIN firstmate relays a work request to one of its SECONDMATES,
# bin/fm-send.sh prepends this marker to the message text. A secondmate is itself
# a firstmate running in its own home, so without a marker it treats every
# incoming fm-send/tmux line as if its captain typed it and answers
# CONVERSATIONALLY in its own chat. But the main firstmate never reads a
# secondmate's chat: the only main<-secondmate wakeup channel is the status file
# (charter escalation), optionally pointing to a doc for detail. A detailed
# chat-only reply therefore strands, unseen.
#
# The marker lets the secondmate tell its supervisor's request apart from a
# message the captain typed directly into its pane:
#
#   - marked   -> a from-firstmate request. Do the work, then respond via the
#                 STATUS/ESCALATION path (a status line for a terse result, or a
#                 doc plus a status pointer - the scout-report pattern - for a
#                 detailed one) so it surfaces to the main firstmate via the
#                 watcher signal. It MUST NOT respond only in chat.
#   - unmarked -> the captain typing directly. Stay conversational, exactly as
#                 before: authoritative captain intervention.
#
# This contract lives in the generated secondmate charter (bin/fm-brief.sh) so it
# travels with the live secondmate, and is summarized in AGENTS.md.
#
# Distinct from the afk daemon marker, on purpose.
# The away-mode daemon (bin/fm-supervise-daemon.sh) marks its daemon->firstmate
# escalations with a BARE leading unit separator (FM_INJECT_MARK, ASCII 0x1f).
# This from-firstmate marker mirrors that CONCEPT - it reuses the ASCII unit
# separator (0x1f), which is untypable on a normal keyboard, as the "a human can
# never forge this" guarantee - but it is a DISTINCT sequence: a human-readable
# label FOLLOWED by the separator, never a bare leading 0x1f. The afk contract
# keys on a LEADING 0x1f, which this marker never has, so the two cannot
# conflate: a secondmate's own afk machinery never mistakes a from-firstmate
# request for an internal daemon escalation, and vice versa. The visible label is
# also what the secondmate's LLM actually reads in its pane, since the separator
# byte itself is invisible.
#
# Sourced by bin/fm-send.sh, bin/fm-brief.sh, bin/fm-classify-lib.sh, and the
# tests. No side effects on source. set -u / set -e safe.

# The label field: human-readable, greppable, and distinctive enough that the
# captain would not type it by hand. This is the part the secondmate's LLM reads.
FM_FROMFIRST_LABEL='[fm-from-firstmate]'

# The full marker fm-send prepends to a from-firstmate request: the label, then
# the ASCII unit separator (0x1f) as the untypable field separator. The request
# text follows the separator.
FM_FROMFIRST_MARK="${FM_FROMFIRST_LABEL}"$'\x1f'

# fm_message_from_firstmate: 0 (true) if <message> carries the from-firstmate
# marker - it begins with the label immediately followed by the unit separator -
# and 1 otherwise. The unit separator is untypable, so a captain-typed message,
# even one that happens to start with the label text alone, is never matched.
fm_message_from_firstmate() {  # <message>
  case "$1" in
    "$FM_FROMFIRST_MARK"*) return 0 ;;
  esac
  return 1
}

# --- Outstanding from-firstmate request -------------------------------------
#
# A marked request has one return channel: the secondmate's status file in the
# main home (state/<id>.status). A secondmate pane is exempt from stale-pane
# detection because idling on its own watcher is healthy, so a secondmate whose
# turn dies after receiving a request would otherwise be indistinguishable from a
# healthy idle home and the request would vanish. fm-send therefore records each
# delivered marked request in the target's state/<id>.meta:
#
#   fm_request_ts=<epoch>          when the request was sent
#   fm_request_status_bytes=<n>    byte size of state/<id>.status just before send
#   fm_request=<summary>           first 80 chars of the request, one line
#
# The request counts as answered as soon as the status file grows past the
# recorded size (a status line, or the status pointer to a detailed doc).
# The watcher judges answered/overdue through the shared classifier
# (secondmate_request_verdict in bin/fm-classify-lib.sh), clears an answered
# request silently, and surfaces an overdue one exactly once as a
# "check: secondmate-request: ..." wake, then clears it.
# While an older request is still unanswered a newer send keeps the older
# timestamp, so the timeout measures the oldest outstanding request.

FM_FROMFIRST_REQUEST_KEYS_RE='^fm_request=|^fm_request_ts=|^fm_request_status_bytes='

# fm_fromfirst_status_bytes: byte size of <status-file>, 0 when absent.
fm_fromfirst_status_bytes() {  # <status-file>
  local n
  [ -f "$1" ] || { printf '0'; return 0; }
  n=$(wc -c < "$1" 2>/dev/null | tr -d '[:space:]')
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  printf '%s' "$n"
}

fm_fromfirst_meta_field() {  # <meta> <key>
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

# Rewrite <meta> without the request fields, then append <extra> (may be empty).
# Atomic via a sibling temp file and rename.
_fm_fromfirst_meta_rewrite() {  # <meta> <extra-lines>
  local meta=$1 extra=$2 tmp
  [ -f "$meta" ] || return 1
  tmp=$(mktemp "${meta%/*}/.${meta##*/}.fm-req.XXXXXX") || return 1
  if ! { grep -vE "$FM_FROMFIRST_REQUEST_KEYS_RE" "$meta" || true; } > "$tmp"; then
    rm -f "$tmp"; return 1
  fi
  if [ -n "$extra" ]; then
    printf '%s\n' "$extra" >> "$tmp" || { rm -f "$tmp"; return 1; }
  fi
  mv -f "$tmp" "$meta" || { rm -f "$tmp"; return 1; }
}

# fm_fromfirst_request_record: note a delivered marked request in <meta>.
# <status-bytes> is the status file size captured BEFORE the send, so a reply
# that lands while fm-send is still settling is never mistaken for silence.
# Keeps an older request that is still unanswered.
fm_fromfirst_request_record() {  # <meta> <epoch> <status-bytes> <request-text>
  local meta=$1 ts=$2 bytes=$3 text=$4 old_ts old_bytes cur summary
  [ -f "$meta" ] || return 1
  old_ts=$(fm_fromfirst_meta_field "$meta" fm_request_ts)
  if [ -n "$old_ts" ]; then
    old_bytes=$(fm_fromfirst_meta_field "$meta" fm_request_status_bytes)
    cur=$(fm_fromfirst_status_bytes "${meta%.meta}.status")
    case "$old_bytes" in ''|*[!0-9]*) old_bytes=0 ;; esac
    [ "$cur" -gt "$old_bytes" ] || return 0
  fi
  summary=$(printf '%s' "$text" | tr '\n\r\t\037' '    ' | cut -c1-80)
  _fm_fromfirst_meta_rewrite "$meta" "$(printf 'fm_request_ts=%s\nfm_request_status_bytes=%s\nfm_request=%s' "$ts" "$bytes" "$summary")"
}

# fm_fromfirst_request_clear: drop the outstanding request from <meta>. With
# <expected-ts>, clear only if the recorded request is still that one, so a newer
# request recorded meanwhile is not erased.
fm_fromfirst_request_clear() {  # <meta> [expected-ts]
  local meta=$1 expect=${2:-} cur
  [ -f "$meta" ] || return 0
  cur=$(fm_fromfirst_meta_field "$meta" fm_request_ts)
  [ -n "$cur" ] || return 0
  [ -z "$expect" ] || [ "$cur" = "$expect" ] || return 0
  _fm_fromfirst_meta_rewrite "$meta" ""
}
