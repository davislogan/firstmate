#!/usr/bin/env bash
# fm-send submit verdicts (incident fm-send-enter-swallow).
#
# fm-send used to report "Enter swallowed; text left in composer" for steers
# that had landed: Claude Code's empty composer is the prompt glyph plus a
# NO-BREAK SPACE, which read as pending text, and an agent that exited after
# taking the line (/exit) left a shell prompt that also read as pending text.
# These tests pin the corrected verdicts hermetically (stubbed tmux + sleep,
# composer bytes copied from a live Claude Code v2.1.312 pane):
#   1. A busy agent that queued the message ("Press up to edit queued messages")
#      is a successful send.
#   2. A genuine swallow (real text still in the agent's composer) fails loudly,
#      after retrying Enter only, never retyping.
#   3. An agent that exits after taking the line (/exit) is a successful send
#      with a note, not a swallow.
#   4. A pane that was already a bare shell fails with "no agent running".
#   5. A bare shell that runs the line as a still-running command (a relaunch)
#      is a successful send with a note.
#   6. A bare shell after a send whose prior agent state is unknown fails with
#      an explicit "cannot tell" message instead of claiming a swallow.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SEND="$ROOT/bin/fm-send.sh"
TMP_ROOT=$(fm_test_tmproot fm-send-verdict)

# A fake tmux whose composer row and foreground command are scripted per case.
#   FM_FAKE_COMPOSER  file holding the styled cursor row capture-pane -e returns.
#   FM_FAKE_CMDS      file of pane_current_command values, one per line; each
#                     query consumes the first line and the last line sticks.
#   FM_TMUX_LOG       send-keys calls are appended here.
make_stubs() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    shift
    printf '%s\n' "$*" >> "$FM_TMUX_LOG"
    exit 0 ;;
  display-message)
    for a in "$@"; do
      case "$a" in
        *cursor_y*) printf '0\n'; exit 0 ;;
        *pane_current_command*)
          head -1 "$FM_FAKE_CMDS"
          if [ "$(wc -l < "$FM_FAKE_CMDS")" -gt 1 ]; then
            tail -n +2 "$FM_FAKE_CMDS" > "$FM_FAKE_CMDS.next" && mv "$FM_FAKE_CMDS.next" "$FM_FAKE_CMDS"
          fi
          exit 0 ;;
      esac
    done
    printf '%%1\n'; exit 0 ;;
  capture-pane) cat "$FM_FAKE_COMPOSER"; exit 0 ;;
  list-windows) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/sleep"
  printf '%s\n' "$fb"
}

# run_case <name> <composer-printf-format> <cmd...>
# Runs fm-send against a recorded task whose pane serves the given composer row
# and foreground-command sequence. Sets RC, OUT (stderr), and LOG (send-keys).
run_case() {
  local name=$1 composer=$2 dir fb home
  shift 2
  dir="$TMP_ROOT/$name"; home="$dir/home"
  mkdir -p "$home/state"
  fb=$(make_stubs "$dir")
  printf 'window=sess:1\nharness=claude\nkind=ship\n' > "$home/state/task.meta"
  # shellcheck disable=SC2059
  printf "$composer" > "$dir/composer"
  printf '%s\n' "$@" > "$dir/cmds"
  : > "$dir/tmux.log"
  OUT=$(PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" \
    FM_FAKE_COMPOSER="$dir/composer" FM_FAKE_CMDS="$dir/cmds" FM_TMUX_LOG="$dir/tmux.log" \
    "$SEND" task "steer text" 2>&1 >/dev/null)
  RC=$?
  LOG=$(cat "$dir/tmux.log")
}

NBSP_PROMPT='\033[38;5;246m\xe2\x9d\xaf\xc2\xa0\033[39m'
SHELL_PROMPT='artsc@host:~/work$ \n'

test_busy_agent_queued_send_succeeds() {
  run_case busy "${NBSP_PROMPT}\033[2m\033[39mPress up to edit queued messages\033[0m\n" claude claude
  expect_code 0 "$RC" "busy queued send should succeed; stderr: $OUT"
  case "$OUT" in *error*) fail "busy queued send printed an error: $OUT" ;; esac
  pass "fm-send: a busy agent that queued the message is a successful send"
}

test_genuine_swallow_fails_loudly() {
  local enters
  run_case swallow "${NBSP_PROMPT}steer text\n" claude claude
  expect_code 1 "$RC" "genuine swallow should fail"
  case "$OUT" in
    *"still in the agent's composer after 3 Enter attempts"*) : ;;
    *) fail "genuine swallow: unexpected message: $OUT" ;;
  esac
  enters=$(printf '%s\n' "$LOG" | grep -c 'Enter$')
  [ "$enters" = 3 ] || fail "genuine swallow: expected 3 Enter retries, got $enters"$'\n'"$LOG"
  [ "$(printf '%s\n' "$LOG" | grep -c -- '-l')" = 1 ] || fail "genuine swallow: text was retyped"$'\n'"$LOG"
  pass "fm-send: a genuine swallow fails loudly after Enter-only retries"
}

test_agent_exit_after_submit_succeeds() {
  run_case exit "$SHELL_PROMPT" claude bash
  expect_code 0 "$RC" "/exit send should succeed; stderr: $OUT"
  case "$OUT" in
    *"exited after the text was submitted"*) : ;;
    *) fail "/exit send: missing exit note: $OUT" ;;
  esac
  case "$OUT" in *error*) fail "/exit send printed an error: $OUT" ;; esac
  pass "fm-send: an agent exiting after taking the line is a successful send"
}

test_bare_shell_target_fails() {
  run_case bare "$SHELL_PROMPT" bash bash
  expect_code 1 "$RC" "send to a bare shell should fail"
  case "$OUT" in
    *"no agent running"*) : ;;
    *) fail "bare shell: unexpected message: $OUT" ;;
  esac
  case "$OUT" in *swallowed*) fail "bare shell still claims a swallow: $OUT" ;; esac
  pass "fm-send: a send to a bare shell fails with 'no agent running'"
}

test_shell_relaunch_succeeds() {
  run_case relaunch "${NBSP_PROMPT}steer text\n" bash claude
  expect_code 0 "$RC" "relaunch from a bare shell should succeed; stderr: $OUT"
  case "$OUT" in
    *"run as a shell command"*) : ;;
    *) fail "relaunch: missing shell-command note: $OUT" ;;
  esac
  pass "fm-send: a line run by a bare shell as a still-running command succeeds"
}

test_unknown_prior_state_is_honest() {
  run_case unknown "$SHELL_PROMPT" node bash
  expect_code 1 "$RC" "unknown-then-shell should fail"
  case "$OUT" in
    *"cannot tell whether the agent received the text"*) : ;;
    *) fail "unknown prior state: unexpected message: $OUT" ;;
  esac
  pass "fm-send: an unverifiable outcome says so instead of claiming a swallow"
}

test_busy_agent_queued_send_succeeds
test_genuine_swallow_fails_loudly
test_agent_exit_after_submit_succeeds
test_bare_shell_target_fails
test_shell_relaunch_succeeds
test_unknown_prior_state_is_honest
