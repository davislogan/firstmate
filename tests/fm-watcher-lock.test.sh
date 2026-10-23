#!/usr/bin/env bash
# tests/fm-watcher-lock.test.sh - watcher singleton + lock-primitive races +
# PID identity stability + watch-arm liveness + guard warnings. These are
# safety-critical process invariants (a race bug may not reproduce through an
# e2e), so they stay as focused real-process units.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
WATCH_ARM="$ROOT/bin/fm-watch-arm.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
LIB="$ROOT/bin/fm-wake-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-watcher-lock-tests)
# Detached watchers outlive their arms by design, so stop any a case left
# behind before the scratch dirs go away (stop_case_watchers, below).
trap 'stop_case_watchers; rm -rf "$TMP_ROOT"' EXIT


test_singleton_start() {
  local dir state fakebin out1 out2 pid1 pid2 live i
  dir=$(make_case singleton)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out1="$dir/watch-one.out"
  out2="$dir/watch-two.out"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out1" &
  pid1=$!
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out2" &
  pid2=$!
  i=0
  while [ "$i" -lt 50 ]; do
    live=0
    is_live_non_zombie "$pid1" && live=$((live + 1))
    is_live_non_zombie "$pid2" && live=$((live + 1))
    [ "$live" -eq 1 ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ "$live" -eq 1 ] || fail "expected exactly one live watcher, got $live"
  grep -h 'watcher: already running pid ' "$out1" "$out2" >/dev/null || fail "second watcher did not report existing singleton"
  kill "$pid1" "$pid2" 2>/dev/null || true
  wait "$pid1" 2>/dev/null || true
  wait "$pid2" 2>/dev/null || true
  pass "simultaneous watcher starts leave exactly one live process"
}

test_stale_watch_lock_reclaimed() {
  local dir state fakebin out dead_pid pid live lock_pid i
  dir=$(make_case stale-lock)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  dead_pid=999999
  while kill -0 "$dead_pid" 2>/dev/null; do
    dead_pid=$((dead_pid + 1))
  done
  mkdir "$state/.watch.lock"
  printf '%s\n' "$dead_pid" > "$state/.watch.lock/pid"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  i=0
  live=0
  lock_pid=
  while [ "$i" -lt 50 ]; do
    live=0
    is_live_non_zombie "$pid" && live=1
    lock_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
    [ "$live" -eq 1 ] && [ "$lock_pid" != "$dead_pid" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ "$live" -eq 1 ] || fail "watcher did not reclaim stale lock and stay alive"
  [ "$lock_pid" != "$dead_pid" ] || fail "stale watch lock pid was not replaced"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  pass "killed watcher stale lock is reclaimed"
}

test_live_stale_watch_lock_is_actionable() {
  local dir state fakebin out err status
  dir=$(make_case live-stale-lock)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  err="$dir/watch.err"
  mkdir "$state/.watch.lock"
  printf '%s\n' "$$" > "$state/.watch.lock/pid"
  touch -t 200001010000 "$state/.last-watcher-beat"
  status=0
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=1 FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" 2> "$err" || status=$?
  [ "$status" -ne 0 ] || fail "watcher silently no-opped behind a live stale holder"
  grep -F 'heartbeat is stale' "$err" >/dev/null || fail "watcher did not explain the stale live lock"
  pass "live watcher lock with stale heartbeat is actionable"
}

test_guard_warnings() {
  # The guard's two operator-visible states, with resilient substrings instead of
  # four copy-coupled tests:
  #   (1) watcher DOWN + queued wakes: a prominent no-watcher banner leads (alarm
  #       title, in-flight count, beacon age, fix command), the queued-wakes
  #       warning follows it, and the guidance is re-arm-after-drain (never the
  #       old conflicting "restart NOW first").
  #   (2) a fresh watcher and an empty queue: total silence.
  local dir state err first banner_line queue_line
  dir=$(make_case guard)
  state="$dir/state"
  err="$dir/guard.err"

  # (1) watcher down (no beacon) + two in-flight tasks + a queued wake.
  # FM_ROOT_OVERRIDE points the worktree-tangle check at a non-git dir so it stays
  # inert here; this case is about the watcher-down banner, not the tangle guard.
  printf 'project=x\n' > "$state/task.meta"
  printf 'project=y\n' > "$state/task2.meta"
  append_wake "$state" heartbeat heartbeat heartbeat || fail "guard heartbeat append failed"
  FM_ROOT_OVERRIDE="$dir" FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=1 "$ROOT/bin/fm-guard.sh" 2> "$err" >/dev/null || fail "guard failed"
  first=$(grep -v '^[[:space:]]*$' "$err" | head -1)
  case "$first" in
    '●'*) ;;
    *) fail "no-watcher banner is not the first thing the guard prints (got '$first')" ;;
  esac
  grep -F 'WATCHER DOWN - SUPERVISION IS OFF' "$err" >/dev/null || fail "guard banner missing the alarm title"
  grep -F '2 task(s) in flight' "$err" >/dev/null || fail "guard banner missing the in-flight count"
  grep -F 'last beat: never' "$err" >/dev/null || fail "guard banner missing the beacon age"
  grep -F 'guarded operation WILL still run' "$err" >/dev/null || fail "guard banner missing generic continuation wording"
  ! grep -F 'requested message WILL still be sent' "$err" >/dev/null || fail "shared guard used send-specific continuation wording"
  grep -F 'resume supervision' "$err" >/dev/null || fail "guard banner missing the harness-aware fix command"
  grep -F 'queued wakes pending - drain them' "$err" >/dev/null || fail "guard did not warn about pending queue"
  grep -F 'After draining queued wakes, resume supervision' "$err" >/dev/null || fail "guard did not order supervision repair after drain"
  ! grep -F 'Restart it NOW, before anything else' "$err" >/dev/null || fail "guard still gave conflicting restart-first instruction"
  ! grep -F 'as the harness-tracked background task' "$err" >/dev/null || fail "guard still printed the old universal background-task repair text"
  banner_line=$(grep -n 'WATCHER DOWN' "$err" | head -1 | cut -d: -f1)
  queue_line=$(grep -n 'queued wakes pending - drain them' "$err" | head -1 | cut -d: -f1)
  [ "$banner_line" -lt "$queue_line" ] || fail "queued-wakes warning printed before the no-watcher banner"

  dir=$(make_case guard-xmode)
  state="$dir/state"
  err="$dir/guard.err"
  mkdir -p "$dir/config"
  printf 'project=x\n' > "$state/task.meta"
  : > "$dir/config/x-mode.env"
  FM_ROOT_OVERRIDE="$dir" FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=1 "$ROOT/bin/fm-guard.sh" 2> "$err" >/dev/null || fail "guard failed"
  grep -F "source '$dir/config/x-mode.env' first" "$err" >/dev/null || fail "guard repair line did not source the X-mode cadence config"

  # (2) fresh watcher, empty queue -> silence.
  dir=$(make_case guard-fresh)
  state="$dir/state"
  err="$dir/guard.err"
  printf 'project=x\n' > "$state/task.meta"
  touch "$state/.last-watcher-beat"
  # Non-git FM_ROOT keeps the worktree-tangle check inert so "fresh watcher ->
  # total silence" stays a pure assertion about watcher state.
  FM_ROOT_OVERRIDE="$dir" FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=300 "$ROOT/bin/fm-guard.sh" 2> "$err" >/dev/null || fail "guard failed"
  [ ! -s "$err" ] || fail "guard warned with a fresh watcher and no queued wakes: $(cat "$err")"
  pass "guard banner leads when down with pending wakes (re-arm-after-drain) and stays silent when fresh"
}

test_lock_single_winner_under_concurrency() {
  local dir state lockdir marker i pids pid wins
  dir=$(make_case lock-concurrency)
  state="$dir/state"
  lockdir="$state/.contend.lock"
  marker="$dir/wins"
  : > "$marker"
  pids=
  i=1
  while [ "$i" -le 40 ]; do
    FM_STATE_OVERRIDE="$state" bash -c '
      . "$1"
      if fm_lock_try_acquire "$2"; then
        printf "%s\n" "$$" >> "$3"
        # Stay alive so the held lock names a live pid for the whole window;
        # otherwise a late contender could legitimately reclaim a dead-pid lock.
        sleep 1
      fi
    ' _ "$LIB" "$lockdir" "$marker" &
    pids="$pids $!"
    i=$((i + 1))
  done
  for pid in $pids; do
    wait "$pid" 2>/dev/null || true
  done
  wins=$(awk 'NF { c++ } END { print c + 0 }' "$marker")
  [ "$wins" -eq 1 ] || fail "expected exactly one lock winner under concurrency, got $wins"
  pass "concurrent fm_lock_try_acquire yields exactly one winner"
}

test_lock_steals_dead_pid_lock() {
  local dir state lockdir dead rc newpid
  dir=$(make_case lock-dead-steal)
  state="$dir/state"
  lockdir="$state/.contend.lock"
  dead=$(dead_pid)
  mkdir "$lockdir"
  printf '%s\n' "$dead" > "$lockdir/pid"
  rc=0
  newpid=$(FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    if fm_lock_try_acquire "$2"; then cat "$2/pid"; else exit 7; fi
  ' _ "$LIB" "$lockdir") || rc=$?
  [ "$rc" -eq 0 ] || fail "acquirer failed to steal a dead-pid stale lock (rc=$rc)"
  [ "$newpid" != "$dead" ] || fail "stale dead-pid lock was not replaced (still $dead)"
  [ -n "$newpid" ] || fail "reclaimed lock has no pid recorded"
  pass "dead-pid stale lock is reclaimed by a single acquirer"
}

test_lock_stale_steal_single_winner_under_concurrency() {
  local dir state lockdir dead marker i pids pid wins
  dir=$(make_case lock-stale-concurrency)
  state="$dir/state"
  lockdir="$state/.contend.lock"
  marker="$dir/wins"
  dead=$(dead_pid)
  mkdir "$lockdir"
  printf '%s\n' "$dead" > "$lockdir/pid"
  : > "$marker"
  pids=
  i=1
  while [ "$i" -le 40 ]; do
    FM_STATE_OVERRIDE="$state" bash -c '
      . "$1"
      if fm_lock_try_acquire "$2"; then
        printf "%s\n" "${BASHPID:-$$}" >> "$3"
        sleep 1
      fi
    ' _ "$LIB" "$lockdir" "$marker" &
    pids="$pids $!"
    i=$((i + 1))
  done
  for pid in $pids; do
    wait "$pid" 2>/dev/null || true
  done
  wins=$(awk 'NF { c++ } END { print c + 0 }' "$marker")
  [ "$wins" -eq 1 ] || fail "expected exactly one stale-lock stealer, got $wins"
  pass "concurrent stale-lock steal yields exactly one winner"
}

test_lock_live_steal_mutex_is_not_reclaimed() {
  local dir state lockdir dead holder_file holder out i lockpid stealpid
  dir=$(make_case lock-live-stealer)
  state="$dir/state"
  lockdir="$state/.contend.lock"
  holder_file="$dir/holder"
  dead=$(dead_pid)
  mkdir "$lockdir"
  printf '%s\n' "$dead" > "$lockdir/pid"
  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    fm_lock_try_acquire "$2.steal" || exit 7
    printf "%s\n" "${BASHPID:-$$}" > "$3"
    sleep 2
    fm_lock_release "$2.steal"
  ' _ "$LIB" "$lockdir" "$holder_file" &
  holder=$!
  i=0
  while [ "$i" -lt 50 ] && [ ! -s "$holder_file" ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -s "$holder_file" ] || fail "live steal mutex holder did not start"
  out=$(FM_LOCK_STALE_AFTER=0 FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    if fm_lock_try_acquire "$2"; then rc=0; else rc=1; fi
    printf "rc=%s held=%s lockpid=%s stealpid=%s\n" "$rc" "${FM_LOCK_HELD_PID:-}" "$(cat "$2/pid" 2>/dev/null || true)" "$(cat "$2.steal/pid" 2>/dev/null || true)"
  ' _ "$LIB" "$lockdir")
  wait "$holder" || fail "live steal mutex holder failed"
  case "$out" in
    *"rc=1"*) ;;
    *) fail "stale lock was stolen while a live stealer held the mutex: $out" ;;
  esac
  lockpid=${out#*lockpid=}; lockpid=${lockpid%% *}
  stealpid=${out#*stealpid=}; stealpid=${stealpid%% *}
  [ "$lockpid" = "$dead" ] || fail "primary lock changed while live steal mutex was held: $out"
  [ "$stealpid" = "$(cat "$holder_file")" ] || fail "live steal mutex owner changed: $out"
  pass "live steal mutex is not reclaimed"
}

test_lock_does_not_steal_live_lock() {
  local dir state lockdir live out lockpid
  dir=$(make_case lock-live-noop)
  state="$dir/state"
  lockdir="$state/.contend.lock"
  sleep 300 &
  live=$!
  mkdir "$lockdir"
  printf '%s\n' "$live" > "$lockdir/pid"
  out=$(FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    if fm_lock_try_acquire "$2"; then rc=0; else rc=1; fi
    printf "rc=%s held=%s\n" "$rc" "${FM_LOCK_HELD_PID:-}"
  ' _ "$LIB" "$lockdir")
  kill "$live" 2>/dev/null || true
  wait "$live" 2>/dev/null || true
  case "$out" in
    *"rc=1"*) ;;
    *) fail "live-held lock was acquired instead of refused: $out" ;;
  esac
  case "$out" in
    *"held=$live"*) ;;
    *) fail "live holder pid not reported via FM_LOCK_HELD_PID: $out" ;;
  esac
  lockpid=$(cat "$lockdir/pid" 2>/dev/null || true)
  [ "$lockpid" = "$live" ] || fail "live holder's lock pid was clobbered (got '$lockpid')"
  pass "live-held lock is not stolen"
}

test_lock_empty_pid_uses_minimum_grace() {
  local dir state lockdir out
  dir=$(make_case lock-empty-grace)
  state="$dir/state"
  lockdir="$state/.contend.lock"
  mkdir "$lockdir"
  out=$(FM_LOCK_STALE_AFTER=0 FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    if fm_lock_try_acquire "$2"; then rc=0; else rc=1; fi
    printf "rc=%s held=%s\n" "$rc" "${FM_LOCK_HELD_PID:-}"
  ' _ "$LIB" "$lockdir")
  case "$out" in
    *"rc=1"*) ;;
    *) fail "empty mid-acquire lock was stolen with zero stale threshold: $out" ;;
  esac
  [ -d "$lockdir" ] || fail "empty mid-acquire lock dir was removed during grace"
  [ ! -e "$lockdir/pid" ] || fail "empty mid-acquire lock gained a pid during grace"
  pass "empty mid-acquire lock keeps a minimum grace"
}

test_lock_late_claim_loses_after_recreate() {
  local dir state lockdir out
  dir=$(make_case lock-late-claim)
  state="$dir/state"
  lockdir="$state/.contend.lock"
  out=$(FM_LOCK_STALE_AFTER=0 FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    owner1=$(fm_lock_owner_dir "$2") || exit 20
    ln -s "$owner1" "$2" || exit 21
    touch -h -t 200001010000 "$2" 2>/dev/null || sleep 2
    if ! fm_lock_try_acquire "$2"; then exit 22; fi
    before=$(cat "$2/pid" 2>/dev/null || true)
    if fm_lock_claim "$2" "$owner1"; then late=won; else late=lost; fi
    after=$(cat "$2/pid" 2>/dev/null || true)
    current_owner=$(readlink "$2" 2>/dev/null || true)
    printf "late=%s before=%s after=%s owner_changed=%s\n" "$late" "$before" "$after" "$([ "$current_owner" != "$owner1" ] && echo yes || echo no)"
  ' _ "$LIB" "$lockdir")
  case "$out" in
    *"late=lost"*) ;;
    *) fail "late original claimant succeeded after lock recreation: $out" ;;
  esac
  case "$out" in
    *"owner_changed=yes"*) ;;
    *) fail "stale owner was not replaced before late claim: $out" ;;
  esac
  before=${out#*before=}; before=${before%% *}
  after=${out#*after=}; after=${after%% *}
  [ -n "$before" ] || fail "recreated lock did not record a pid: $out"
  [ "$before" = "$after" ] || fail "late claim changed the recreated lock pid: $out"
  pass "late original claimant cannot claim a recreated lock"
}

test_lock_paused_mid_acquire_claim_fails_during_steal() {
  local dir state lockdir out pid
  dir=$(make_case lock-paused-claim-steal)
  state="$dir/state"
  lockdir="$state/.contend.lock"
  out=$(FM_LOCK_STALE_AFTER=0 FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    owner=$(fm_lock_owner_dir "$2") || exit 20
    ln -s "$owner" "$2" || exit 21
    fm_lock_try_acquire "$2.steal" || exit 22
    steal_owner=${FM_LOCK_OWNER_DIR:-}
    if fm_lock_claim "$2" "$owner"; then late=won; else late=lost; fi
    if fm_lock_try_create "$2" "$steal_owner"; then stealer=won; else stealer=lost; fi
    pid=$(cat "$2/pid" 2>/dev/null || true)
    printf "late=%s stealer=%s pid=%s\n" "$late" "$stealer" "$pid"
  ' _ "$LIB" "$lockdir")
  case "$out" in
    *"late=lost"*) ;;
    *) fail "paused claimant succeeded while steal mutex was held: $out" ;;
  esac
  case "$out" in
    *"stealer=won"*) ;;
    *) fail "stealer could not claim after paused claimant backed off: $out" ;;
  esac
  pid=${out#*pid=}; pid=${pid%% *}
  [ -n "$pid" ] || fail "stealer claim did not record a pid: $out"
  pass "paused mid-acquire claimant backs off to active stealer"
}

test_watch_restart_rejects_reused_pid() {
  local dir state fakebin out live pid i lock_pid
  dir=$(make_case restart-reused-pid)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/restart.out"
  sleep 300 &
  live=$!
  mkdir "$state/.watch.lock"
  printf '%s\n' "$live" > "$state/.watch.lock/pid"
  printf '%s\n' "$dir" > "$state/.watch.lock/fm-home"
  printf '%s\n' "$WATCH" > "$state/.watch.lock/watcher-path"
  printf '%s\n' "stale watcher identity" > "$state/.watch.lock/pid-identity"
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH_ARM" --restart > "$out" &
  pid=$!
  # The honest arm forks the fresh watcher as a tracked child and waits on it, so
  # the lock now names that child, not the arm invocation. The property is the
  # same: the stale reused-pid lock is replaced by a genuinely live watcher, which
  # the arm confirms before reporting it. Wait for that confirmation, not just for
  # the lock pid to appear (identity and beacon land a beat later).
  i=0
  while [ "$i" -lt 80 ]; do
    grep -qF 'watcher: started pid=' "$out" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  lock_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  { [ -n "$lock_pid" ] && [ "$lock_pid" != "$live" ] && kill -0 "$lock_pid" 2>/dev/null; } \
    || fail "restart did not replace stale reused-pid lock with a live watcher (got '$lock_pid')"
  grep -F "watcher: started pid=$lock_pid" "$out" >/dev/null || fail "restart did not report the fresh watcher it confirmed"
  is_live_non_zombie "$live" || fail "restart killed a reused unrelated pid"
  kill "$pid" "$lock_pid" "$live" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  wait "$live" 2>/dev/null || true
  pass "watch restart refuses to signal a reused pid"
}

test_watch_restart_reports_healthy_peer_without_attaching() {
  local dir state fakebin out peer identity armpid status
  dir=$(make_case restart-healthy-peer)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/restart.out"
  node -e 'process.on("SIGTERM", () => {}); setTimeout(() => {}, 300000)' &
  peer=$!
  identity=$(FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$peer") || fail "could not identify peer pid"
  mkdir "$state/.watch.lock"
  printf '%s\n' "$peer" > "$state/.watch.lock/pid"
  printf '%s\n' "$dir" > "$state/.watch.lock/fm-home"
  printf '%s\n' "$WATCH" > "$state/.watch.lock/watcher-path"
  printf '%s\n' "$identity" > "$state/.watch.lock/pid-identity"
  touch "$state/.last-watcher-beat"
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_ARM_ATTACH_POLL=0.1 "$WATCH_ARM" --restart > "$out" &
  armpid=$!
  # Restart mode first sends TERM to the TERM-resistant peer and waits up to 5s
  # (50 * 0.1s, hardcoded in fm-watch-arm.sh) for it to die before proceeding, so
  # this budget must clear that deterministic floor with real headroom under load.
  wait_for_exit "$armpid" 200
  status=$?
  [ "$status" -eq 0 ] || fail "restart did not exit zero after reporting healthy peer (status $status): $(cat "$out")"
  grep -qF "watcher: healthy pid=$peer" "$out" || fail "restart did not report the healthy peer: $(cat "$out")"
  ! grep -qF 'watcher: attached' "$out" || fail "restart attached to a peer watcher instead of preserving restart ownership contract"
  is_live_non_zombie "$peer" || fail "restart killed a TERM-resistant peer unexpectedly"
  kill -KILL "$peer" 2>/dev/null || true
  wait "$peer" 2>/dev/null || true
  pass "watch restart reports a healthy peer without attaching to it"
}

test_watcher_self_evicts_on_lock_takeover() {
  local dir state fakebin out pid i lock_pid
  dir=$(make_case self-evict)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=0.2 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  i=0
  while [ "$i" -lt 50 ]; do
    [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$pid" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$pid" ] || fail "watcher did not record its own pid in the lock"
  # Simulate a second watcher taking over the singleton lock. $$ (the test
  # runner) is a live pid that is not the watcher.
  printf '%s\n' "$$" > "$state/.watch.lock/pid"
  wait_for_exit "$pid" 60 || fail "watcher did not self-evict after lock takeover"
  lock_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  [ "$lock_pid" = "$$" ] || fail "self-evicting watcher clobbered the new holder's lock (got '$lock_pid')"
  pass "watcher self-evicts when the lock pid no longer names it"
}

test_arm_attaches_and_waits_for_live_fresh_watcher() {
  local dir state fakebin out armout i wpid armpid status
  dir=$(make_case arm-attach)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  armout="$dir/arm.out"
  # A genuinely live watcher with a fresh beacon already holds the singleton.
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  wpid=$!
  i=0
  while [ "$i" -lt 60 ]; do
    [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$wpid" ] && [ -e "$state/.last-watcher-beat" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$wpid" ] || fail "seed watcher did not take the lock"
  # Arming must attach to the existing watcher, NOT start a second one, and NOT
  # exit while the seed still holds the healthy lock.
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_ARM_ATTACH_POLL=0.1 "$WATCH_ARM" > "$armout" &
  armpid=$!
  i=0
  while [ "$i" -lt 80 ]; do
    grep -qF "watcher: attached pid=$wpid" "$armout" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  grep -qF "watcher: attached pid=$wpid" "$armout" || fail "arm did not report attach to the live watcher"
  ! grep -qF 'watcher: started' "$armout" || fail "arm started a second watcher behind a healthy one"
  ! grep -qF 'watcher: FAILED' "$armout" || fail "arm reported FAILED for a healthy watcher"
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$wpid" ] || fail "arm disturbed the healthy watcher's lock"
  is_live_non_zombie "$armpid" || fail "arm exited while the seed watcher was still healthy"
  # After the seed dies, the attached arm must exit 0 (cycle ended).
  kill "$wpid" 2>/dev/null || true
  wait "$wpid" 2>/dev/null || true
  wait_for_exit "$armpid" 80
  status=$?
  [ "$status" -eq 0 ] || fail "attached arm did not exit zero after seed died (status $status)"
  pass "arm attaches to a live fresh watcher and exits only when that cycle ends"
}

test_arm_starts_and_self_heals() {
  # Arming with no confirmable watcher must FORK one and confirm it live + fresh
  # before reporting 'started' - whether the lock is empty (clean start) or held
  # by a dead pid with a fresh-looking leftover beacon (self-heal). It must never
  # report 'healthy' off a dead pid. One row per pre-state, one assertion block.
  local row dir state fakebin armout armpid i lock_pid dead_pid
  for row in clean dead-pid; do
    dir=$(make_case "arm-$row")
    state="$dir/state"
    fakebin="$dir/fakebin"
    armout="$dir/arm.out"
    dead_pid=
    if [ "$row" = dead-pid ]; then
      dead_pid=999999
      while kill -0 "$dead_pid" 2>/dev/null; do dead_pid=$((dead_pid + 1)); done
      mkdir "$state/.watch.lock"
      printf '%s\n' "$dead_pid" > "$state/.watch.lock/pid"
      printf '%s\n' "$dir" > "$state/.watch.lock/fm-home"
      printf '%s\n' "$WATCH" > "$state/.watch.lock/watcher-path"
      printf '%s\n' "dead watcher identity" > "$state/.watch.lock/pid-identity"
      touch "$state/.last-watcher-beat"
    fi
    PATH="$fakebin:$PATH" FM_HOME="$dir" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH_ARM" > "$armout" &
    armpid=$!
    i=0
    while [ "$i" -lt 80 ]; do
      grep -qF 'watcher: started pid=' "$armout" 2>/dev/null && break
      sleep 0.1; i=$((i + 1))
    done
    grep -qF 'watcher: started pid=' "$armout" || fail "arm ($row) did not report a started watcher"
    ! grep -qE 'watcher: (healthy|attached)' "$armout" || fail "arm ($row) wrongly reported attached/healthy instead of starting a fresh watcher"
    lock_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
    # The 'started' line prints only after the fresh watcher passed (live pid +
    # fresh beacon), so it doubles as proof the beacon was confirmed fresh.
    grep -F "watcher: started pid=$lock_pid (beacon fresh)" "$armout" >/dev/null \
      || fail "arm ($row) started line did not name the confirmed live watcher (lock '$lock_pid')"
    kill -0 "$lock_pid" 2>/dev/null || fail "arm ($row) confirmed-started watcher is not actually alive"
    [ -z "$dead_pid" ] || [ "$lock_pid" != "$dead_pid" ] || fail "arm ($row) did not replace the dead-pid lock with a live watcher"
    kill "$armpid" "$lock_pid" 2>/dev/null || true
    wait "$armpid" 2>/dev/null || true
  done
  pass "arm starts+confirms a fresh watcher on a clean lock and self-heals a dead-pid lock (never healthy off a dead pid)"
}

# Wait until <file> shows <fixed-string>, up to <limit> tenths of a second.
wait_for_line() {  # <file> <fixed-string> [limit]
  local file=$1 want=$2 limit=${3:-80} i=0
  while [ "$i" -lt "$limit" ]; do
    grep -qF "$want" "$file" 2>/dev/null && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

# Wait for <pid> (not necessarily our child) to be gone, up to <limit> tenths.
wait_for_gone() {  # <pid> [limit]
  local pid=$1 limit=${2:-80} i=0
  while [ "$i" -lt "$limit" ]; do
    is_live_non_zombie "$pid" || return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

# Count live detached watchers for <state>: every detached watcher writes its
# output to .watch-cycle-<pid>.out, so a live fm-watch.sh pid behind one of
# those files is a running watcher for this home.
count_live_detached_watchers() {  # <state>
  local state=$1 f pid n=0
  for f in "$state"/.watch-cycle-*.out; do
    [ -e "$f" ] || continue
    pid=${f##*/.watch-cycle-}
    pid=${pid%.out}
    is_live_non_zombie "$pid" || continue
    ps -p "$pid" -o args= 2>/dev/null | grep -q 'fm-watch\.sh' || continue
    n=$((n + 1))
  done
  printf '%s\n' "$n"
}

# Wait until <state> has exactly <n> live detached watchers, up to 5s.
wait_for_detached_count() {  # <state> <n>
  local i=0
  while [ "$i" -lt 50 ]; do
    [ "$(count_live_detached_watchers "$1")" -eq "$2" ] && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

# Detached watchers outlive their arms by design; stop any a test left behind
# (only pids recorded in this suite's own scratch state dirs).
stop_case_watchers() {
  local lockpid pid
  for lockpid in "$TMP_ROOT"/*/state/.watch.lock/pid; do
    [ -e "$lockpid" ] || continue
    pid=$(cat "$lockpid" 2>/dev/null || true)
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    ps -p "$pid" -o args= 2>/dev/null | grep -q 'fm-watch\.sh' || continue
    kill "$pid" 2>/dev/null || true
  done
}

test_arm_death_leaves_detached_watcher_reattachable() {
  # Reaping the arm (HUP from a closed terminal, TERM from a harness task limit,
  # KILL from anything) must end only the attach: the watcher keeps its lock,
  # keeps beating, and a fresh arm attaches to it instead of starting another.
  local sig dir state fakebin armout armout2 armpid armpid2 lock_pid status
  for sig in HUP TERM KILL; do
    dir=$(make_case "arm-death-$sig")
    state="$dir/state"
    fakebin="$dir/fakebin"
    armout="$dir/arm.out"
    armout2="$dir/arm2.out"
    PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=0.2 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_ARM_ATTACH_POLL=0.1 "$WATCH_ARM" > "$armout" &
    armpid=$!
    wait_for_line "$armout" 'watcher: started pid=' || fail "arm ($sig) did not start a watcher: $(cat "$armout")"
    lock_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
    [ -e "$state/.watch.lock/detached" ] || fail "arm ($sig) started a watcher without the detached lock marker"
    kill -"$sig" "$armpid" 2>/dev/null || fail "could not send $sig to arm"
    wait_for_exit "$armpid" 80
    status=$?
    [ "$status" -ne 0 ] || fail "arm ($sig) exited zero after being signalled"
    touch -t 200001010000 "$state/.last-watcher-beat"
    sleep 1
    is_live_non_zombie "$lock_pid" || fail "killing the arm with $sig killed the watcher"
    [ "$(FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_path_age "$2"' _ "$LIB" "$state/.last-watcher-beat")" -lt 5 ] || fail "watcher stopped beating after its arm got $sig"
    [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$lock_pid" ] || fail "watcher lost its lock after its arm got $sig"
    PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_ARM_ATTACH_POLL=0.1 "$WATCH_ARM" > "$armout2" &
    armpid2=$!
    wait_for_line "$armout2" "watcher: attached pid=$lock_pid" || fail "fresh arm ($sig) did not re-attach to the surviving watcher: $(cat "$armout2")"
    ! grep -qF 'watcher: started' "$armout2" || fail "fresh arm ($sig) started a second watcher"
    kill "$lock_pid" 2>/dev/null || true
    wait_for_exit "$armpid2" 80
    status=$?
    [ "$status" -ne 124 ] || fail "re-attached arm ($sig) never returned after the watcher ended"
  done
  pass "arm death (HUP, TERM, KILL) leaves the detached watcher beating and re-attachable"
}

test_concurrent_arms_leave_one_watcher() {
  local dir state fakebin n i pids pid live wpids
  dir=$(make_case arm-concurrency)
  state="$dir/state"
  fakebin="$dir/fakebin"
  n=8
  pids=
  i=1
  while [ "$i" -le "$n" ]; do
    PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=0.2 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_ARM_ATTACH_POLL=0.1 "$WATCH_ARM" > "$dir/arm.$i.out" 2>&1 &
    pids="$pids $!"
    i=$((i + 1))
  done
  i=1
  while [ "$i" -le "$n" ]; do
    wait_for_line "$dir/arm.$i.out" 'watcher: ' || fail "arm $i reported nothing"
    ! grep -qF 'watcher: FAILED' "$dir/arm.$i.out" || fail "arm $i failed under concurrency: $(cat "$dir/arm.$i.out")"
    i=$((i + 1))
  done
  # Give any transient duplicate a few polls to self-evict before counting.
  sleep 1
  live=$(count_live_detached_watchers "$state")
  [ "$live" -eq 1 ] || fail "expected exactly one live watcher after $n concurrent arms, got $live"
  wpids=$(cat "$dir"/arm.*.out | sed -n 's/^watcher: \(started\|attached\) pid=\([0-9]*\).*/\2/p' | sort -u)
  [ "$(printf '%s\n' "$wpids" | awk 'NF' | wc -l | tr -d ' ')" -eq 1 ] || fail "concurrent arms named more than one watcher: $wpids"
  [ "$wpids" = "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" ] || fail "arms did not converge on the lock holder"
  for pid in $pids; do
    is_live_non_zombie "$pid" || fail "an arm exited while the single watcher was still healthy"
  done
  for pid in $pids; do kill -KILL "$pid" 2>/dev/null || true; done
  for pid in $pids; do wait "$pid" 2>/dev/null || true; done
  is_live_non_zombie "$wpids" || fail "killing every arm killed the watcher"
  kill "$wpids" 2>/dev/null || true
  pass "N concurrent arms leave exactly one detached watcher"
}

test_detached_watcher_expires_when_idle_and_unattached() {
  local dir state fakebin armout armpid lock_pid ttl start elapsed
  dir=$(make_case arm-detached-expiry)
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/arm.out"
  ttl=2
  : > "$state/task.meta"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=0.2 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_ARM_ATTACH_POLL=0.1 FM_WATCH_DETACHED_TTL=$ttl "$WATCH_ARM" > "$armout" &
  armpid=$!
  wait_for_line "$armout" 'watcher: started pid=' || fail "arm did not start a watcher: $(cat "$armout")"
  lock_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  # Attached with nothing in flight: the attach beacon keeps it alive past the TTL.
  rm -f "$state/task.meta"
  sleep $((ttl + 2))
  is_live_non_zombie "$lock_pid" || fail "detached watcher expired while an arm was still attached"
  kill -KILL "$armpid" 2>/dev/null || true
  wait "$armpid" 2>/dev/null || true
  # Unattached but with work in flight: it must keep supervising past the TTL.
  : > "$state/task.meta"
  sleep $((ttl + 2))
  is_live_non_zombie "$lock_pid" || fail "detached watcher expired with a task still in flight"
  # Nothing in flight and nobody attached: it ends itself within the bound.
  rm -f "$state/task.meta"
  start=$(date +%s)
  wait_for_gone "$lock_pid" $(((ttl + 4) * 10)) || fail "idle unattached detached watcher outlived its ${ttl}s bound"
  elapsed=$(( $(date +%s) - start ))
  [ "$elapsed" -ge $((ttl - 1)) ] || fail "detached watcher expired too early (${elapsed}s < ${ttl}s bound)"
  [ ! -e "$state/.watch.lock" ] || fail "expired watcher left its lock behind"
  grep -qF 'detached watcher expired' "$state/.watch-triage.log" || fail "expiry was not logged"
  pass "idle unattached detached watcher expires within FM_WATCH_DETACHED_TTL, and not while attached or with work in flight"
}

test_unattached_wake_is_queued_and_drained() {
  # A wake that lands while no arm is attached must still reach firstmate: the
  # watcher queues it before exiting, the next arm returns it at once instead of
  # blocking on a new cycle, and fm-wake-drain.sh drains it.
  local dir state fakebin armout armout2 drain_out armpid lock_pid check_file rc
  dir=$(make_case arm-unattached-wake)
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/arm.out"
  armout2="$dir/arm2.out"
  drain_out="$dir/drain.out"
  check_file="$state/task.check.sh"
  : > "$state/task.meta"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=0.2 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=1 FM_HEARTBEAT=999999 FM_ARM_ATTACH_POLL=0.1 "$WATCH_ARM" > "$armout" &
  armpid=$!
  wait_for_line "$armout" 'watcher: started pid=' || fail "arm did not start a watcher: $(cat "$armout")"
  lock_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  kill -KILL "$armpid" 2>/dev/null || true
  wait "$armpid" 2>/dev/null || true
  cat > "$check_file" <<'SH'
#!/usr/bin/env bash
printf 'merged: https://example.test/pr/9\n'
SH
  chmod +x "$check_file"
  wait_for_gone "$lock_pid" 80 || fail "unattached watcher did not exit on its actionable wake"
  [ "$(cat "$state/.watch-cycle-$lock_pid.rc" 2>/dev/null || true)" = 0 ] || fail "unattached watcher did not record a clean wake exit"
  rc=0
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_ARM_CONFIRM_TIMEOUT=3 "$WATCH_ARM" > "$armout2" || rc=$?
  [ "$rc" -eq 0 ] || fail "arm over a pending queue exited $rc: $(cat "$armout2")"
  grep -F "check: $check_file: merged: https://example.test/pr/9" "$armout2" >/dev/null || fail "arm did not return the queued wake: $(cat "$armout2")"
  ! grep -qE 'watcher: (started|attached)' "$armout2" || fail "arm blocked on a new cycle while wakes were queued"
  rm -f "$check_file"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain failed"
  grep "$(printf '\tcheck\t')" "$drain_out" | grep -F 'merged: https://example.test/pr/9' >/dev/null || fail "unattached wake was not drained: $(cat "$drain_out")"
  [ ! -s "$state/.wake-queue" ] || fail "drain left the queue non-empty"
  pass "a wake raised while no arm is attached is queued, returned by the next arm, and drained"
}

test_arm_propagates_immediate_wake_before_confirmation() {
  local dir state fakebin armout drain_out check_file rc
  dir=$(make_case arm-immediate-wake)
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/arm.out"
  drain_out="$dir/drain.out"
  check_file="$state/task.check.sh"
  cat > "$check_file" <<'SH'
#!/usr/bin/env bash
printf 'merged: https://example.test/pr/7\n'
SH
  chmod +x "$check_file"
  rc=0
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=0 FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=0 FM_HEARTBEAT=999999 "$WATCH_ARM" > "$armout" || rc=$?
  [ "$rc" -eq 0 ] || fail "arm returned non-zero for an immediate wake (status $rc): $(cat "$armout")"
  grep -F "check: $check_file: merged: https://example.test/pr/7" "$armout" >/dev/null || fail "arm did not propagate the immediate check wake"
  ! grep -qF 'watcher: FAILED' "$armout" || fail "arm printed FAILED after a valid immediate wake"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" || fail "drain after immediate arm wake failed"
  grep "$(printf '\tcheck\t')" "$drain_out" | grep -F "$check_file" | grep -F 'merged: https://example.test/pr/7' >/dev/null || fail "immediate arm wake was not queued"
  pass "arm propagates an immediate watcher wake before confirmation"
}

test_arm_waits_for_peer_beacon_after_child_stands_down() {
  local dir state fakebin armout peer beater identity armpid status i
  dir=$(make_case arm-peer-startup-race)
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/arm.out"
  sleep 300 &
  peer=$!
  identity=$(FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$peer") || fail "could not identify peer pid"
  mkdir "$state/.watch.lock"
  printf '%s\n' "$peer" > "$state/.watch.lock/pid"
  printf '%s\n' "$dir" > "$state/.watch.lock/fm-home"
  printf '%s\n' "$WATCH" > "$state/.watch.lock/watcher-path"
  printf '%s\n' "$identity" > "$state/.watch.lock/pid-identity"
  (
    sleep 1
    touch "$state/.last-watcher-beat"
  ) &
  beater=$!
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_ARM_CONFIRM_TIMEOUT=4 FM_ARM_ATTACH_POLL=0.1 "$WATCH_ARM" > "$armout" &
  armpid=$!
  i=0
  while [ "$i" -lt 80 ]; do
    grep -qF "watcher: attached pid=$peer" "$armout" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  wait "$beater" 2>/dev/null || true
  grep -qF "watcher: attached pid=$peer" "$armout" || fail "arm did not wait for and attach to the peer watcher: $(cat "$armout")"
  ! grep -qF 'watcher: FAILED' "$armout" || fail "arm falsely reported FAILED during peer startup race"
  is_live_non_zombie "$armpid" || fail "arm exited while the peer was still healthy"
  # After the peer dies, the attached arm must exit 0 (same as pre-fork attach).
  kill "$peer" 2>/dev/null || true
  wait "$peer" 2>/dev/null || true
  wait_for_exit "$armpid" 80
  status=$?
  [ "$status" -eq 0 ] || fail "attached arm did not exit zero after peer died (status $status): $(cat "$armout")"
  pass "arm attaches to a peer watcher after child stands down and exits when peer dies"
}

test_arm_fails_loud_when_no_fresh_watcher_confirmable() {
  local dir state fakebin armout live armpid status
  dir=$(make_case arm-failed-stale)
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/arm.out"
  sleep 300 &
  live=$!
  # A live process holds the lock but is NOT a confirmable watcher (no identity),
  # and the beacon is stale. The fresh child cannot steal a LIVE lock, so no
  # watcher can ever be confirmed - the honest answer is FAILED, not healthy.
  mkdir "$state/.watch.lock"
  printf '%s\n' "$live" > "$state/.watch.lock/pid"
  touch -t 200001010000 "$state/.last-watcher-beat"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_ARM_CONFIRM_TIMEOUT=3 "$WATCH_ARM" > "$armout" &
  armpid=$!
  wait_for_exit "$armpid" 120
  status=$?
  [ "$status" -ne 124 ] || fail "arm never returned for an unconfirmable watcher"
  [ "$status" -ne 0 ] || fail "arm exited zero when no fresh watcher could be confirmed"
  grep -F 'watcher: FAILED - no live watcher with a fresh beacon' "$armout" >/dev/null || fail "arm did not print the FAILED line"
  ! grep -qE 'watcher: (healthy|attached)' "$armout" || fail "arm reported attached/healthy off a stale beacon"
  ! grep -qF 'watcher: started' "$armout" || fail "arm falsely reported started"
  is_live_non_zombie "$live" || fail "arm killed the unrelated live lock holder"
  wait_for_detached_count "$state" 0 || fail "arm left its unconfirmed watcher running after FAILED"
  kill "$live" 2>/dev/null || true
  wait "$live" 2>/dev/null || true
  pass "arm reports FAILED, exits non-zero, and stops its unconfirmed watcher when no fresh watcher can be confirmed"
}

# Start a real watcher holding <dir>'s lock (detached when <detached> is 1) and
# wait until its lock records identity and its beacon is fresh; sets HOLDER_PID.
HOLDER_PID=
start_lock_holder() {  # <dir> <detached>
  local dir=$1 detached=$2 pid i
  PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_WATCH_DETACHED="$detached" FM_POLL=0.2 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$dir/holder.out" 2>&1 &
  pid=$!
  i=0
  while [ "$i" -lt 80 ]; do
    [ "$(cat "$dir/state/.watch.lock/pid" 2>/dev/null || true)" = "$pid" ] \
      && [ -s "$dir/state/.watch.lock/pid-identity" ] && [ -e "$dir/state/.last-watcher-beat" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  HOLDER_PID=$pid
}

# Run one bounded watcher start against <dir> with the given extra env; output
# lands in <dir>/taker.out and <dir>/taker.err. Sets TAKER_PID.
TAKER_PID=
start_taker() {  # <dir> [VAR=value...]
  local dir=$1
  shift
  env "$@" PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_POLL=0.2 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$dir/taker.out" 2> "$dir/taker.err" &
  TAKER_PID=$!
}

backdate_attach() { touch -t 200001010000 "$1/state/.watch-attached"; }

test_takeover_evicts_unattached_detached_holder() {
  local dir state holder taker i
  dir=$(make_case takeover-stale-attach)
  state="$dir/state"
  start_lock_holder "$dir" 1
  holder=$HOLDER_PID
  [ -e "$state/.watch.lock/detached" ] || fail "seed detached watcher did not mark its lock"
  backdate_attach "$dir"
  start_taker "$dir" FM_WATCH_TAKEOVER=test-taker
  taker=$TAKER_PID
  wait_for_gone "$holder" 100 || fail "opted-in start did not evict the unattached detached holder"
  i=0
  while [ "$i" -lt 80 ]; do
    [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$taker" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$taker" ] || fail "taker does not hold the lock after takeover"
  is_live_non_zombie "$taker" || fail "taker exited instead of supervising"
  [ ! -e "$state/.watch.lock/detached" ] || fail "taker kept the detached marker"
  grep -F "watcher takeover: test-taker evicted detached watcher pid $holder" "$state/.watch-triage.log" >/dev/null || fail "takeover was not logged to the triage log"
  grep -F "watcher takeover: test-taker evicted detached watcher pid $holder" "$dir/taker.err" >/dev/null || fail "takeover was not reported on stderr"
  grep -E 'beacon [0-9]+s, attach beacon [0-9]+s' "$dir/taker.err" >/dev/null || fail "takeover line did not name beacon ages: $(cat "$dir/taker.err")"
  kill "$taker" 2>/dev/null || true
  wait "$taker" 2>/dev/null || true
  pass "opted-in start takes over a detached watcher whose attach beacon is stale, and logs it"
}

test_takeover_refuses_unsafe_holders() {
  # Every refusal must leave the holder alive and the start on the ordinary
  # "already running" path: a fresh attach beacon (an arm attaching now), no
  # opt-in (plain start and fm-watch-arm.sh), an opted-in start that is itself
  # detached, a lock naming another home or a mismatched identity, and a
  # holder that is not detached.
  local row dir state holder taker status armpid
  for row in fresh-attach no-opt-in detached-taker other-home bad-identity non-detached; do
    dir=$(make_case "takeover-refuse-$row")
    state="$dir/state"
    if [ "$row" = non-detached ]; then
      start_lock_holder "$dir" 0
    else
      start_lock_holder "$dir" 1
    fi
    holder=$HOLDER_PID
    is_live_non_zombie "$holder" || fail "($row) seed watcher is not running"
    backdate_attach "$dir"
    case "$row" in
      fresh-attach) touch "$state/.watch-attached" ;;
      other-home) printf '%s\n' "$TMP_ROOT/another-home" > "$state/.watch.lock/fm-home" ;;
      bad-identity) printf '%s\n' "not this watcher" > "$state/.watch.lock/pid-identity" ;;
    esac
    case "$row" in
      no-opt-in) start_taker "$dir" ;;
      detached-taker) start_taker "$dir" FM_WATCH_TAKEOVER=test-taker FM_WATCH_DETACHED=1 ;;
      *) start_taker "$dir" FM_WATCH_TAKEOVER=test-taker ;;
    esac
    taker=$TAKER_PID
    wait_for_exit "$taker" 100
    status=$?
    [ "$status" -eq 0 ] || fail "($row) refused start did not exit zero (status $status): $(cat "$dir/taker.out" "$dir/taker.err")"
    grep -F "watcher: already running pid $holder" "$dir/taker.out" >/dev/null || fail "($row) refused start did not report already running: $(cat "$dir/taker.out" "$dir/taker.err")"
    is_live_non_zombie "$holder" || fail "($row) the holder was signalled"
    [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$holder" ] || fail "($row) the holder lost its lock"
    ! grep -qF 'watcher takeover' "$dir/taker.err" "$state/.watch-triage.log" 2>/dev/null || fail "($row) a takeover was logged"
    if [ "$row" = no-opt-in ]; then
      backdate_attach "$dir"
      PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_ARM_ATTACH_POLL=0.1 "$WATCH_ARM" > "$dir/arm.out" 2>&1 &
      armpid=$!
      wait_for_line "$dir/arm.out" "watcher: attached pid=$holder" || fail "arm did not attach to the stale-attach detached holder: $(cat "$dir/arm.out")"
      is_live_non_zombie "$holder" || fail "fm-watch-arm.sh took over a detached holder"
      kill "$armpid" 2>/dev/null || true
      wait "$armpid" 2>/dev/null || true
    fi
    kill "$holder" 2>/dev/null || true
    wait "$holder" 2>/dev/null || true
  done
  pass "takeover refuses a freshly attached, non-opted-in, detached-taker, other-home, mismatched-identity, or non-detached holder"
}

test_arm_prunes_orphan_cycle_output() {
  local dir state dead_pid live rc
  dir=$(make_case arm-prune-orphans)
  state="$dir/state"
  dead_pid=999999
  while kill -0 "$dead_pid" 2>/dev/null; do dead_pid=$((dead_pid + 1)); done
  sleep 300 &
  live=$!
  printf 'orphan\n' > "$state/.watch-cycle-$dead_pid.out"
  printf 'live\n' > "$state/.watch-cycle-$live.out"
  touch -t 200001010000 "$state/.watch-cycle-$dead_pid.out" "$state/.watch-cycle-$live.out"
  append_wake "$state" heartbeat heartbeat heartbeat || fail "could not queue a wake"
  rc=0
  PATH="$dir/fakebin:$PATH" FM_STATE_OVERRIDE="$state" "$WATCH_ARM" > "$dir/arm.out" 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || fail "arm over a pending queue exited $rc: $(cat "$dir/arm.out")"
  [ ! -e "$state/.watch-cycle-$dead_pid.out" ] || fail "arm kept an old cycle output whose watcher is dead and left no status"
  [ -e "$state/.watch-cycle-$live.out" ] || fail "arm pruned a cycle output whose pid is still alive"
  kill "$live" 2>/dev/null || true
  wait "$live" 2>/dev/null || true
  pass "arm prunes old cycle output left by a dead watcher with no status, and keeps a live one"
}

test_pid_identity_is_locale_invariant() {
  # The watcher records its process identity under one locale; arm/guard/turn-end
  # re-read it under the machine's ambient locale. ps's lstart date format follows
  # LC_TIME, so an unpinned read on a non-C locale (e.g. ko_KR) would differ only
  # in the date portion and reject a genuinely live watcher. The fix pins LC_ALL=C
  # inside fm_pid_identity, so its output must be byte-identical regardless of the
  # caller's exported LC_ALL/LC_TIME. That invariant holds on any host because the
  # pin is internal, so this stays deterministic on CI even where an alternate
  # locale like ko_KR.UTF-8 is not installed (the equality then holds trivially).
  local live baseline via_lc_all via_lc_time
  sleep 300 &
  live=$!
  baseline=$(LC_ALL=C bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$live" 2>/dev/null)
  via_lc_all=$(LC_ALL=ko_KR.UTF-8 bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$live" 2>/dev/null)
  via_lc_time=$(LC_TIME=ko_KR.UTF-8 bash -c 'unset LC_ALL; . "$1"; fm_pid_identity "$2"' _ "$LIB" "$live" 2>/dev/null)
  kill "$live" 2>/dev/null || true
  wait "$live" 2>/dev/null || true
  [ -n "$baseline" ] || fail "fm_pid_identity produced no baseline identity under LC_ALL=C"
  [ "$via_lc_all" = "$baseline" ] || fail "fm_pid_identity varied with exported LC_ALL (got '$via_lc_all', want '$baseline')"
  [ "$via_lc_time" = "$baseline" ] || fail "fm_pid_identity varied with exported LC_TIME (got '$via_lc_time', want '$baseline')"
  pass "fm_pid_identity is locale-invariant across LC_ALL/LC_TIME"
}

test_singleton_start
test_pid_identity_is_locale_invariant
test_stale_watch_lock_reclaimed
test_live_stale_watch_lock_is_actionable
test_guard_warnings
test_lock_single_winner_under_concurrency
test_lock_steals_dead_pid_lock
test_lock_stale_steal_single_winner_under_concurrency
test_lock_live_steal_mutex_is_not_reclaimed
test_lock_does_not_steal_live_lock
test_lock_empty_pid_uses_minimum_grace
test_lock_late_claim_loses_after_recreate
test_lock_paused_mid_acquire_claim_fails_during_steal
test_watch_restart_rejects_reused_pid
test_watch_restart_reports_healthy_peer_without_attaching
test_watcher_self_evicts_on_lock_takeover
test_arm_attaches_and_waits_for_live_fresh_watcher
test_arm_starts_and_self_heals
test_arm_death_leaves_detached_watcher_reattachable
test_concurrent_arms_leave_one_watcher
test_detached_watcher_expires_when_idle_and_unattached
test_unattached_wake_is_queued_and_drained
test_arm_propagates_immediate_wake_before_confirmation
test_arm_waits_for_peer_beacon_after_child_stands_down
test_arm_fails_loud_when_no_fresh_watcher_confirmable
test_takeover_evicts_unattached_detached_holder
test_takeover_refuses_unsafe_holders
test_arm_prunes_orphan_cycle_output
