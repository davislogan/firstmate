#!/usr/bin/env bash
# fm-tmux-lib.sh - shared tmux pane primitives for firstmate.
#
# ONE source of truth for: busy detection (the per-harness footer set, the
# claude subagent-wait signature, and the text-level busy verdict),
# composer-empty (pending-input) detection, and a verify-and-retry-Enter submit.
# Sourced by the always-on watcher (bin/fm-watch.sh), the away-mode daemon
# (bin/fm-supervise-daemon.sh), bin/fm-crew-state.sh, and the tmux backend
# adapter (bin/backends/tmux.sh, which bin/fm-send.sh reaches through
# bin/fm-backend.sh) so the busy and composer/submit logic cannot drift.
#
# Why this exists (incident afk-invx-i5): the daemon's old composer check only
# recognized a BARE prompt glyph ("> ") as an empty composer. claude draws its
# input box with box-drawing borders ("│ > … │"), so every idle claude pane read
# as "pending input" and the away-mode daemon deferred 100% of escalations for
# 9.5 hours with no escape. The detector below strips the box borders before
# deciding, so a bordered-but-empty composer is correctly seen as empty. The same
# corrected detector backs the submit acknowledgement (a submit "landed" iff the
# composer is empty afterward), fixing the parallel false "Enter swallowed".
#
# Ghost text (incident composer-robust): claude renders a predicted-next-prompt
# "suggestion" as dim/faint text inside an otherwise-empty composer. A plain
# capture cannot tell it apart from text a human typed, so the old reader saw an
# idle pane as holding pending input and the daemon deferred injection / firstmate
# misjudged the pane. The composer reader now captures just the cursor line WITH
# ANSI styling (tmux capture-pane -e), drops dim/faint (SGR 2) runs, and decides on
# what is left, so ghost/placeholder text never counts as real input. The styled
# capture is consumed internally and parsed into a boolean here; it is NEVER
# surfaced (fm-peek and every human/LLM-facing path stay plain), and only the
# single composer row is captured, so no escape-laden pane bulk is produced. This
# is harness-generic: any harness that dims placeholder/ghost text benefits.
#
# Per-harness override: FM_COMPOSER_IDLE_RE matches an empty composer after
# dim-ghost and structural border stripping. FM_BUSY_REGEX overrides the busy
# footer set everywhere (fm-watch.sh, the daemon, fm-crew-state.sh).
#
# All functions are `set -u` and `set -e` safe (guarded tmux calls, explicit
# returns) so they can be sourced into either context.

# Busy footers per harness. This is the ONE owner of the default set:
# bin/fm-watch.sh, the daemon, and fm-crew-state.sh source this file and reach
# it through fm_text_shows_busy (the daemon's inject guard also reads it
# directly). claude/codex: "esc to interrupt"; opencode: "esc interrupt";
# pi: "Working..."; grok: "Ctrl+c:cancel"
# (grok's mid-turn cancel hint, shown iff a turn is running - verified grok 0.2.73).
# fm_tmux_composer_state also consults this set (a footer on the cursor line is
# not pending input), so it must stay a vocabulary of footer phrases only; the
# subagent-wait signature below is deliberately a SEPARATE predicate for that reason.
FM_TMUX_BUSY_REGEX_DEFAULT='esc (to )?interrupt|Working\.\.\.|Ctrl\+c:cancel'

# Claude subagent-wait signature (verified Claude Code, 2026-09-30). A claude crew
# that dispatches its own background subagents ENDS its turn while they run, so
# the "esc to interrupt" footer is gone; instead the spinner row directly above the
# composer box reads "<glyph> Waiting for N background agents to finish" and a
# roster of running subagents is drawn BELOW the composer. That crew is working.
FM_TMUX_SUBAGENT_WAIT_REGEX_DEFAULT='Waiting for [0-9]+ background agents? to finish'

# fm_tmux_strip_ghost: remove dim/faint (ANSI SGR 2) styled runs from one captured
# composer line, then drop any remaining escape sequences, leaving only the plain,
# normal-intensity text, the text a human actually typed. Dim/faint runs are
# ghost/placeholder text (e.g. claude's predicted-next-prompt suggestion) that
# fills an otherwise-empty composer and must never read as pending input. Reads the
# styled line on stdin (from `tmux capture-pane -e`) and prints plain text on
# stdout. LC_ALL=C makes awk walk bytes, so multibyte glyphs (e.g. ❯) and dim runs
# alike pass through or drop intact without locale-dependent character classes.
# A reset (SGR 0) or normal-intensity (SGR 22) ends a dim run; codes are processed
# left to right within a sequence so "ESC[0;2m" (reset then dim) reads as dim.
fm_tmux_strip_ghost() {
  LC_ALL=C awk '
    function sgr_code(v, b) {
      b = v
      sub(/:.*/, "", b)
      if (b == "") b = "0"
      return b
    }
    function skip_color_payload(a, p, k, mode, code) {
      if (index(a[p], ":") > 0) return p
      if (p >= k) return p
      mode = a[p + 1]
      code = sgr_code(mode)
      if (index(mode, ":") > 0) return p + 1
      if (code == "5") return p + 2
      if (code == "2") return p + 4
      return p + 1
    }
    {
      line = $0; out = ""; dim = 0; n = length(line); i = 1
      while (i <= n) {
        c = substr(line, i, 1)
        if (c == "\033") {            # ESC: consume a CSI ... final-byte sequence
          j = i + 1
          if (substr(line, j, 1) == "[") {
            j++; params = ""
            while (j <= n) {
              cc = substr(line, j, 1)
              if (cc ~ /[@-~]/) break
              params = params cc; j++
            }
            if (j <= n && substr(line, j, 1) == "m") {   # SGR: update dim/faint state
              if (params == "") params = "0"
              k = split(params, a, ";")
              for (p = 1; p <= k; p++) {
                v = a[p]; code = sgr_code(v)
                if (code == "38" || code == "48" || code == "58") {
                  p = skip_color_payload(a, p, k)
                } else if (code == "2") dim = 1
                else if (code == "0" || code == "22") dim = 0
              }
            }
            if (j <= n) { i = j + 1; continue }
          }
          i = i + 1; continue          # lone/other ESC: drop the ESC byte only
        }
        if (dim == 0) out = out c        # keep only normal-intensity bytes
        i++
      }
      print out
    }
  '
}

# fm_tmux_composer_state: classify the cursor/composer line of <target> as
#   empty   - no pending input (blank, a bare prompt, a busy footer, or only dim
#             ghost/placeholder text). Safe to inject; also the positive
#             acknowledgement that a submit landed.
#   pending - real, unsubmitted text on the cursor line (a human mid-typing, or a
#             previous injection whose Enter was swallowed). Defer / retry.
#   unknown - the pane could not be read (tmux error). The caller decides.
#
# The cursor line is captured WITH ANSI styling (capture-pane -e) and bounded to
# the single composer row (-S/-E), then run through fm_tmux_strip_ghost so dim/faint
# ghost text drops out before classification. The styled capture is internal only,
# never surfaced. The detector then strips the harness's box-drawing composer
# borders ("│ … │", heavy "┃", or a plain ASCII "|") using literal-string
# substitution (bash 3.2 safe, locale-independent - no \u escapes, no multibyte
# character classes), and asks whether anything real is left.
fm_tmux_composer_state() {  # <target> -> empty|pending|unknown
  local target=$1 cy raw line stripped
  cy=$(tmux display-message -p -t "$target" '#{cursor_y}' 2>/dev/null) || { printf 'unknown'; return 0; }
  case "$cy" in ''|*[!0-9]*) printf 'unknown'; return 0 ;; esac
  raw=$(tmux capture-pane -e -p -t "$target" -S "$cy" -E "$cy" 2>/dev/null) || { printf 'unknown'; return 0; }
  line=$(printf '%s\n' "$raw" | fm_tmux_strip_ghost)
  # Strip the composer box borders (literal glyphs - no character classes).
  stripped=${line//│/}      # U+2502 light vertical (claude)
  stripped=${stripped//┃/}  # U+2503 heavy vertical
  stripped=${stripped//|/}  # ASCII pipe
  # Trim surrounding whitespace.
  stripped="${stripped#"${stripped%%[![:space:]]*}"}"
  stripped="${stripped%"${stripped##*[![:space:]]}"}"
  # Nothing left inside the box = empty composer.
  [ -n "$stripped" ] || { printf 'empty'; return 0; }
  if [ -n "${FM_COMPOSER_IDLE_RE:-}" ] \
     && printf '%s' "$stripped" | grep -qiE "$FM_COMPOSER_IDLE_RE"; then
    printf 'empty'; return 0
  fi
  # Just a bare prompt glyph = empty composer (idle).
  case "$stripped" in
    '>'|'❯'|'$'|'%'|'#') printf 'empty'; return 0 ;;
  esac
  # A busy footer landing on the cursor line is not pending input.
  if printf '%s' "$stripped" | grep -qiE "${FM_BUSY_REGEX:-$FM_TMUX_BUSY_REGEX_DEFAULT}"; then
    printf 'empty'; return 0
  fi
  printf 'pending'; return 0
}

# fm_pane_input_pending: 0 (pending) if the cursor line holds real unsubmitted
# text, 1 otherwise. An unreadable pane is treated as NOT pending (fail-safe:
# the same bias the old daemon used - an unknown pane defers nothing here).
fm_pane_input_pending() {  # <target>
  [ "$(fm_tmux_composer_state "$1")" = pending ]
}

# fm_text_awaiting_subagents: 0 iff the pane text on stdin shows the claude
# subagent-wait state (FM_TMUX_SUBAGENT_WAIT_REGEX_DEFAULT). Pure text predicate.
#
# Why not just add the phrase to the busy regex: the busy scan deliberately
# checks only the last 6 non-blank lines, because a footer phrase anywhere
# higher up may be stale transcript text. In the subagent-wait state the wait
# row sits ABOVE the composer box, status bar, permissions line, and a roster
# that grows with the subagent count, so it is outside that 6-line window. Why
# not match the roster rows (e.g. "◯ general-purpose ...") instead: their shape
# is undocumented and indistinguishable from ordinary bulleted output. Widening
# the scan for the phrase alone would false-positive on transcript text quoting
# it (a brief or report about this very state). So this anchors structurally:
# the wait phrase must be the whole spinner row (glyph, phrase, optional
# parenthetical) that sits directly above the final composer box's top border
# (the second-to-last "───" rule; the last one is the box's bottom). Anything
# else - no composer found, a normal spinner row, a finished turn - is not a match,
# so a genuinely stopped crew still reads not-busy.
fm_text_awaiting_subagents() {
  LC_ALL=C awk -v re="$FM_TMUX_SUBAGENT_WAIT_REGEX_DEFAULT" '
    /^[[:space:]]*$/ { next }
    { n++; line[n] = $0 }
    END {
      top = 0; last = 0
      for (i = n; i >= 1; i--) {
        if (line[i] ~ /^[[:space:]]*───/) {
          if (!last) last = i
          else { top = i; break }
        }
      }
      if (top < 2) exit 1
      row = "^[[:space:]]*[^[:alnum:][:space:]]+[[:space:]]+" re "([[:space:]]+\\(.*\\))?[[:space:]]*$"
      exit !(line[top - 1] ~ row)
    }'
}

# fm_text_shows_busy: 0 iff the pane text on stdin (a ~40-line tail) shows an
# agent still working: a busy footer in the last 6 non-blank lines
# (FM_BUSY_REGEX, else FM_TMUX_BUSY_REGEX_DEFAULT), OR the claude
# subagent-wait state (fm_text_awaiting_subagents). The one text-level busy
# verdict shared by fm_pane_is_busy, fm-crew-state.sh's non-tmux fallback,
# fm-watch.sh's window_is_busy, and the daemon's stale_window_is_busy.
fm_text_shows_busy() {  # < text
  local re=${FM_BUSY_REGEX:-$FM_TMUX_BUSY_REGEX_DEFAULT} text
  text=$(</dev/stdin)
  printf '%s' "$text" | grep -v '^[[:space:]]*$' | tail -6 | grep -qiE "$re" && return 0
  printf '%s\n' "$text" | fm_text_awaiting_subagents
}

# fm_pane_is_busy: 0 if the pane's 40-line tail shows the agent working
# (fm_text_shows_busy: a busy footer, or claude waiting on its own subagents).
fm_pane_is_busy() {  # <target>
  local win=$1 tail40
  tail40=$(tmux capture-pane -p -t "$win" -S -40 2>/dev/null) || return 1
  printf '%s' "$tail40" | fm_text_shows_busy
}

# fm_tmux_submit_core: type <text> into <target> ONCE, then submit with Enter,
# verifying the composer cleared. Retries Enter ONLY - never retypes, because a
# swallowed Enter leaves our text in the composer and retyping would duplicate
# it. Echoes the final verdict on stdout (empty|pending|unknown|send-failed) so callers can
# pick their own success policy:
#   - the daemon clears its buffer only on "empty" (strict: an unknown pane must
#     not be mistaken for a delivered escalation).
#   - fm-send fails only on "pending" (lenient: a positively-confirmed swallow),
#     so an unreadable pane never turns a normal steer into a false error.
fm_tmux_submit_enter_core() {  # <target> <retries> <enter-sleep>
  local target=$1 retries=$2 sleep_s=$3 i=0 state
  while :; do
    tmux send-keys -t "$target" Enter 2>/dev/null || true
    sleep "$sleep_s"
    state=$(fm_tmux_composer_state "$target")
    [ "$state" = pending ] || { printf '%s' "$state"; return 0; }
    i=$((i + 1))
    [ "$i" -lt "$retries" ] || { printf 'pending'; return 0; }
  done
}

fm_tmux_submit_core() {  # <target> <text> <retries> <enter-sleep> <settle>
  local target=$1 text=$2 retries=$3 sleep_s=$4 settle=$5
  tmux send-keys -t "$target" -l "$text" 2>/dev/null || { printf 'send-failed'; return 0; }
  sleep "$settle"
  fm_tmux_submit_enter_core "$target" "$retries" "$sleep_s"
}
