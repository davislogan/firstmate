#!/usr/bin/env bash
# Safe, home-scoped (re-)arm of the firstmate watcher, with honest verification.
#
# The watcher (bin/fm-watch.sh) blocks until it has an actionable wake to
# surface, then prints one reason line and exits. While state/.afk exists the
# daemon owns triage and the watcher exits on every wake for the daemon to
# classify. Reliability depends on arming through a mechanism that SURVIVES the
# call and NOTIFIES on exit, so firstmate must run this script as the harness's
# own tracked background task (e.g. run_in_background). Run it as its own
# standalone background task, never bundled onto the tail of another command.
# NEVER fire it and forget with a shell `&` inside another call: that backgrounded
# child is reaped when the call returns, leaving NO watcher running and a false
# "already running" off the dying process. That exact mistake silently took
# supervision down for ~30 minutes.
#
# This script launches the watcher DETACHED (its own session, not this script's
# child; see bin/fm-watch.sh "Detached mode"), then VERIFIES the outcome before
# it ATTACHES. Started or found, the watcher is never owned by the arm: killing
# or reaping this arm (SIGTERM, SIGKILL, a harness task limit, a turn ending)
# ends only the attach, never supervision. Singleton safety stays with the
# watcher's own race-proof lock and self-eviction, so N concurrent arms still
# leave exactly one watcher. It confirms a watcher process is genuinely alive AND the
# liveness beacon (state/.last-watcher-beat) is fresh within FM_GUARD_GRACE (the
# single source of truth, shared with fm-watch.sh and fm-guard.sh), and prints
# exactly one unambiguous status line:
#   watcher: started pid=<N> (beacon fresh)              - it launched one and confirmed it
#   watcher: attached pid=<N> (beacon <age>s)            - arm mode found a live+fresh watcher
#                                                          holding the lock; this arm attaches and
#                                                          waits until that cycle ends
#   watcher: healthy pid=<N> (beacon <age>s)             - restart mode found a live+fresh
#                                                          watcher it did not own
#   watcher: FAILED - no live watcher with a fresh beacon  - could not confirm one
# It NEVER reports started/attached/healthy off a stale beacon or a dead/reused pid: a
# stale-beacon or dead-pid holder either self-heals (the fresh child steals the
# dead lock per the singleton self-eviction/steal path and is confirmed) or this
# returns the FAILED line. On started or attached it stays live, touching
# state/.watch-attached, until the identity-matched holder is no longer healthy;
# when that cycle ended with an exit status it replays the cycle's output (the
# same wake reason lines) and exits with the watcher's status, so the harness
# background-notify path is unchanged. A holder that went unhealthy without
# exiting (stale beacon) ends the attach with exit zero. On restart-only healthy
# it exits zero after the duplicate child stands down. On FAILED it exits
# non-zero so the failure is loud. A live cycle already present means re-arm
# attaches - do not start a second watcher.
#
# Pending queue first: if state/.wake-queue already holds records (an actionable
# wake that landed while no arm was attached), the arm prints their reason lines
# and exits zero without starting or attaching, so the harness notifies and
# firstmate drains them with bin/fm-wake-drain.sh instead of blocking on a new
# cycle while they sit unread.
#
# Backward compatible: a healthy watcher started by an older coupled arm carries
# no `detached` lock marker; this arm attaches to it like any other holder.
#
# Handover: a detached watcher with no fresh attach may be taken over by an
# explicit non-detached start (AGENTS.md section 8; bin/fm-watch.sh "Takeover").
# This arm never sets FM_WATCH_TAKEOVER and never takes over a holder.
#
# --restart: stop ONLY this FM_HOME's watcher (the pid recorded in THIS home's
# state/.watch.lock) and own a fresh cycle, or report restart-only healthy if a
# live peer still holds the lock after the duplicate child stands down. It
# resolves and signals exactly that pid, so it can never touch another home's
# watcher. NEVER `pkill -f
# bin/fm-watch.sh`: that pattern matches every firstmate home's watcher
# (secondmate homes run the same script) and would kill siblings. Restart never
# attaches to a peer; it attaches only to the fresh watcher it launched.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

WATCH="$SCRIPT_DIR/fm-watch.sh"
WATCH_LOCK="$STATE/.watch.lock"
BEAT="$STATE/.last-watcher-beat"
# "Fresh" reuses the guard's threshold so there is one definition of liveness.
GRACE=${FM_GUARD_GRACE:-300}
ATTACH_BEAT="$STATE/.watch-attached"
# How long to wait for a freshly launched watcher to acquire the lock and beat.
CONFIRM_TIMEOUT=${FM_ARM_CONFIRM_TIMEOUT:-10}
# Poll interval while attached to an existing healthy watcher.
ATTACH_POLL=${FM_ARM_ATTACH_POLL:-0.5}

clear_stale_recorded_watcher_lock() {
  local lock_home lock_path lock_identity
  lock_home=$(cat "$WATCH_LOCK/fm-home" 2>/dev/null || true)
  lock_path=$(cat "$WATCH_LOCK/watcher-path" 2>/dev/null || true)
  lock_identity=$(cat "$WATCH_LOCK/pid-identity" 2>/dev/null || true)
  [ "$lock_home" = "$FM_HOME" ] || return 0
  [ "$lock_path" = "$WATCH" ] || return 0
  [ -n "$lock_identity" ] || return 0
  fm_lock_remove_path "$WATCH_LOCK" || true
}

# A watcher is "healthy" iff the lock names a live process that is genuinely THIS
# home's watcher (the identity match guards against a recycled/reused pid) AND the
# liveness beacon is fresh within GRACE. Sets HEALTHY_PID on success. This is the
# single honesty gate: a dead pid, a reused pid, or a stale beacon all fail it, so
# this script can never report a watcher that is not really there.
HEALTHY_PID=
healthy_watcher() {
  HEALTHY_PID=
  fm_watcher_healthy "$STATE" "$WATCH" "$GRACE" "$FM_HOME" || return 1
  HEALTHY_PID=$FM_WATCHER_HEALTHY_PID
}

report_attached() {
  local age
  age=$(fm_path_age "$BEAT")
  echo "watcher: attached pid=$HEALTHY_PID (beacon ${age}s)"
}

report_healthy() {
  local age
  age=$(fm_path_age "$BEAT")
  echo "watcher: healthy pid=$HEALTHY_PID (beacon ${age}s)"
}

cycle_out() { printf '%s/.watch-cycle-%s.out\n' "$STATE" "$1"; }
cycle_rc() { printf '%s/.watch-cycle-%s.rc\n' "$STATE" "$1"; }

# Read a finished detached cycle's exit status into CYCLE_RC; 1 if it has none
# (still running, killed without its EXIT trap, or not a detached watcher).
CYCLE_RC=
cycle_finished() {
  CYCLE_RC=$(cat "$(cycle_rc "$1")" 2>/dev/null || true)
  case "$CYCLE_RC" in ''|*[!0-9]*) CYCLE_RC=; return 1 ;; esac
}

# Replay a finished cycle: its output, then exit with its status. A cycle ended
# by a signal (a home-scoped --restart, say) ends the attach with zero, as an
# attach to a watcher that went away always has.
replay_cycle_and_exit() {
  local out
  out=$(cycle_out "$1")
  [ -s "$out" ] && cat "$out"
  [ "$CYCLE_RC" -ge 128 ] && exit 0
  exit "$CYCLE_RC"
}

touch_attach() { touch "$ATTACH_BEAT" 2>/dev/null || true; }

# Drop cycle files of watchers that exited over a minute ago, so the state dir
# does not accumulate them; a minute leaves attachers ample time to replay. An
# output file with no status (its watcher was SIGKILLed before its EXIT trap)
# goes once its pid is dead and the file is equally old.
prune_cycle_files() {
  local f pid
  for f in "$STATE"/.watch-cycle-*.rc; do
    [ -e "$f" ] || continue
    [ "$(fm_path_age "$f")" -ge 60 ] || continue
    pid=${f##*/.watch-cycle-}
    pid=${pid%.rc}
    rm -f "$f" "$(cycle_out "$pid")" 2>/dev/null || true
  done
  for f in "$STATE"/.watch-cycle-*.out; do
    [ -e "$f" ] || continue
    pid=${f##*/.watch-cycle-}
    pid=${pid%.out}
    [ -e "$(cycle_rc "$pid")" ] && continue
    fm_pid_alive "$pid" && continue
    [ "$(fm_path_age "$f")" -ge 60 ] || continue
    rm -f "$f" 2>/dev/null || true
  done
}

# Stay attached until the identity-matched healthy holder is gone, touching the
# attach beacon so the watcher knows a wake path exists. If a different healthy
# watcher appears mid-attach (rare steal), re-attach. When the attached cycle
# finished, replay its reason lines and status; otherwise (killed, or beacon
# stale) exit 0 so the harness notifies and firstmate drains state/.wake-queue.
attach_and_wait() {
  local attached_pid=$1 i
  while :; do
    touch_attach
    if healthy_watcher; then
      if [ "$HEALTHY_PID" != "$attached_pid" ]; then
        attached_pid=$HEALTHY_PID
        report_attached
      fi
      sleep "$ATTACH_POLL"
      continue
    fi
    # The watcher writes its status just before releasing the lock and exiting;
    # allow a moment for the write to land after the lock disappears.
    i=0
    while [ "$i" -lt 10 ]; do
      cycle_finished "$attached_pid" && replay_cycle_and_exit "$attached_pid"
      sleep 0.1
      i=$((i + 1))
    done
    exit 0
  done
}

# Print the queued wake reasons and exit 0 when state/.wake-queue is non-empty.
exit_if_queue_pending() {
  [ -s "$FM_WAKE_QUEUE" ] || return 0
  awk -F '\t' 'NF >= 5 { print $5 }' "$FM_WAKE_QUEUE" | awk '!seen[$0]++'
  exit 0
}

mode=arm
case "${1:-}" in
  ''|arm|--arm) mode=arm ;;
  --restart) mode=restart ;;
  *) echo "usage: $(basename "$0") [--restart]" >&2; exit 2 ;;
esac

touch_attach
prune_cycle_files
exit_if_queue_pending

if [ "$mode" = restart ]; then
  # Home-scoped stop: only the watcher pid recorded in THIS home's lock.
  lock_pid=$(cat "$WATCH_LOCK/pid" 2>/dev/null || true)
  if fm_pid_alive "$lock_pid"; then
    if fm_watcher_lock_matches_pid "$STATE" "$WATCH" "$lock_pid" "$FM_HOME"; then
      kill -TERM "$lock_pid" 2>/dev/null || true
      # Wait for it to actually exit before relaunching, so the fresh watcher
      # either takes a released lock or reclaims a now-dead-pid stale lock instead
      # of seeing the dying one as a live holder and no-opping.
      i=0
      while [ "$i" -lt 50 ] && fm_pid_alive "$lock_pid"; do
        sleep 0.1
        i=$((i + 1))
      done
    else
      clear_stale_recorded_watcher_lock
    fi
  fi
fi

# If a genuinely live+fresh watcher already holds the lock, do not start a second
# one - attach to that cycle and wait until it ends so the harness notify fires
# then, not as an immediate empty wake. (--restart skips this: it just stopped
# this home's watcher and wants a fresh one.)
if [ "$mode" = arm ] && healthy_watcher; then
  report_attached
  attach_and_wait "$HEALTHY_PID"
fi

# Launch a detached watcher and confirm it before attaching. perl (already a
# watcher dependency) puts it in a new session and points its output at the
# per-pid cycle file, then execs it in place, so $! is the watcher's own pid;
# the surrounding subshell exits at once, so the watcher is never this arm's
# child and no signal to or reap of this arm reaches it.
child=$(
  FM_WATCH_DETACHED=1 perl -MPOSIX -e '
    POSIX::setsid();
    my $out = "$ARGV[0]/.watch-cycle-$$.out";
    open(STDOUT, ">", $out) or exit 126;
    open(STDERR, ">&", \*STDOUT) or exit 126;
    exec { $ARGV[1] } $ARGV[1] or exit 127;
  ' "$STATE" "$WATCH" </dev/null >/dev/null 2>&1 &
  echo $!
)
case "$child" in
  ''|*[!0-9]*)
    echo "watcher: FAILED - no live watcher with a fresh beacon"
    exit 1
    ;;
esac

# Verify the outcome: poll until this child is the confirmed healthy watcher, or
# until some other watcher legitimately holds the singleton (a startup race), or
# until the child gives up. Only then print the honest line.
deadline=$(( $(date +%s) + CONFIRM_TIMEOUT ))
child_done=0
while :; do
  touch_attach
  if healthy_watcher; then
    if [ "$HEALTHY_PID" = "$child" ]; then
      echo "watcher: started pid=$child (beacon fresh)"
      attach_and_wait "$child"
    fi
    # Another watcher won the singleton; our child stood down.
    if [ "$mode" = arm ]; then
      report_attached
      rm -f "$(cycle_out "$child")" 2>/dev/null || true
      attach_and_wait "$HEALTHY_PID"
    fi
    report_healthy
    rm -f "$(cycle_out "$child")" 2>/dev/null || true
    exit 0
  fi
  if [ "$child_done" -eq 0 ] && ! fm_pid_alive "$child"; then
    child_done=1
    # A cycle that woke before confirmation (an immediate check, say) is
    # replayed exactly like an attached cycle's end.
    if cycle_finished "$child" && [ "$CYCLE_RC" -eq 0 ] \
      && grep -Eq '^(signal:|stale:|check:|heartbeat($|:))' "$(cycle_out "$child")" 2>/dev/null; then
      replay_cycle_and_exit "$child"
    fi
    rm -f "$(cycle_out "$child")" 2>/dev/null || true
  fi
  [ "$(date +%s)" -ge "$deadline" ] && break
  sleep 0.2
done

echo "watcher: FAILED - no live watcher with a fresh beacon"
if fm_pid_alive "$child" && LC_ALL=C ps -p "$child" -o command= 2>/dev/null | grep -Fq "$WATCH"; then
  kill -TERM "$child" 2>/dev/null || true
fi
exit 1
