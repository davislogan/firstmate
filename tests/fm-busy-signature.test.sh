#!/usr/bin/env bash
# Busy-signature fixtures: FM_TMUX_BUSY_REGEX_DEFAULT must recognize a busy pane
# for every harness, including the claude spinner line that renders without the
# "esc to interrupt" hint, and must NOT match idle panes or a finished-turn
# summary ("Brewed for 1m 54s · done ..."). A false-busy blocks steering and
# afk injections, so the negatives matter as much as the positives.
# Fixtures: tests/fixtures/busy-panes/ (shapes from measured panes, 2026-10-24).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-tmux-lib.sh
. "$ROOT/bin/fm-tmux-lib.sh"

FIX="$ROOT/tests/fixtures/busy-panes"
unset FM_BUSY_REGEX

for f in claude-busy-spinner claude-busy-arrow-tokens claude-busy-thinking \
         claude-busy-esc-hint codex-busy opencode-busy pi-busy grok-busy; do
  fm_text_shows_busy < "$FIX/$f.txt" || fail "$f should read busy"
  # The daemon's inject guard scans the same 6-line tail with the same regex.
  grep -v '^[[:space:]]*$' "$FIX/$f.txt" | tail -6 \
    | grep -qiE "$FM_TMUX_BUSY_REGEX_DEFAULT" || fail "$f should match daemon-style scan"
  pass "$f reads busy"
done

for f in claude-idle claude-finished-summary codex-idle opencode-idle pi-idle grok-idle; do
  if fm_text_shows_busy < "$FIX/$f.txt"; then fail "$f must NOT read busy"; fi
  if grep -v '^[[:space:]]*$' "$FIX/$f.txt" | tail -6 \
       | grep -qiE "$FM_TMUX_BUSY_REGEX_DEFAULT"; then fail "$f must NOT match daemon-style scan"; fi
  pass "$f reads idle"
done

# Spinner-line variants: elapsed forms and ASCII-free separators.
for line in '✻ Noodling… (1h 2m 3s · ↓ 1.2k tokens)' '* Churning… (59s · 3 tokens)'; do
  printf '%s\n' "$line" | fm_text_shows_busy || fail "variant should read busy: $line"
done
for line in '✻ Brewed for 1m 54s · done 8:31 PM' 'took 12s · fine' 'Waiting… for it (soon)'; do
  if printf '%s\n' "$line" | fm_text_shows_busy; then fail "variant must NOT read busy: $line"; fi
done
pass "spinner variants"
