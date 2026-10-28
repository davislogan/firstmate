---
name: afk
description: Enter away-mode supervision. Use when the user invokes /afk (e.g. "/afk", "/afk back in an hour", "going afk"). Sets a durable away-mode flag so the sub-supervisor daemon can self-handle routine wakes and escalate only captain-relevant events as one batched digest, cutting supervision token cost during walk-away stretches. Exit is automatic; any real (unmarked) message returns to full per-wake responsiveness.
user-invocable: true
metadata:
  internal: true
---

# afk

Away-mode supervision. When invoked, `/afk` makes the daemon's token-saving
tradeoff **consented** and **explicit**: the captain is stepping away, so the
sub-supervisor may triage routine wakes in bash instead of waking firstmate's
LLM for each one. Escalations still reach the captain, but as one pre-read,
batched digest rather than per-wake injections.

## What it does

1. **Set the durable away-mode flag:**
   ```sh
   date '+%s' > state/.afk
   ```
   This file survives a firstmate restart: recovery re-enters afk if the
   flag is present.

2. **Ensure the sub-supervisor daemon is running.** Start the helper as its own
   tracked background terminal/session:
   ```sh
   bin/fm-afk-start.sh
   ```
   The helper sets or refreshes `state/.afk`, exits immediately if the identity-backed daemon lock already names a live process, and otherwise execs `bin/fm-supervise-daemon.sh` in the foreground.
   Do not wrap this in `nohup ... &`.
   Codex/herdr can reap fire-and-forget shell children after a tool call
   returns; a tracked background terminal/session keeps the daemon attached to
   the harness lifecycle and survived the real incident reproduction.
   The daemon is **presence-gated**: it injects escalations only while
   `state/.afk` exists, and stays quiet otherwise.

3. **Do not separately arm `fm-watch.sh`.** The daemon manages the watcher as
   its child; the singleton lock no-ops a stray arm harmlessly.

4. **Acknowledge** to the captain that away-mode is active: the daemon will
   self-handle routine wakes, escalate only captain-relevant events, and the
   captain can exit by sending any real message.

## How to exit afk

No `/back` is needed. The first genuine message is the return signal:

- A message **without** the sentinel marker and **not** starting with `/afk` -> the captain is back.
  Clear `state/.afk`, stop the daemon, flush one distilled "while you were out" catch-up (drain `state/.wake-queue`, summarize any pending escalations from `state/.subsuper-escalations` and any `state/.subsuper-inject-wedged` marker, then remove both once handled), and resume full per-wake responsiveness through the emitted primary-harness supervision protocol from session start.
- A message **with** the sentinel marker (`FM_INJECT_MARK`, ASCII 0x1f) -> it
  is a daemon escalation; stay afk and process it.
- Re-invoking `/afk` while already away -> stay afk (refresh the flag); this
  does **not** trigger an exit.

Bias ambiguous cases toward exit: a present captain beats token savings, and
a false exit is self-correcting (the captain re-runs `/afk`).

## Orthogonal to approval authority

afk changes how aggressively firstmate surfaces things, **not who approves
what**. "Away" never means "approves more." A PR ready for merge, a
needs-decision finding, or anything destructive still waits for the captain's
explicit word - the daemon just batches the notification.

## Sentinel marker contract

The daemon prefixes every injection with `FM_INJECT_MARK` (ASCII unit
separator, 0x1f), invisible and untypable. This is how firstmate tells a
daemon escalation apart from a real message in the same pane. The marker
travels with the message text; it does not rely on harness-level
typed-vs-injected detection (which is not portable across claude, codex,
opencode, pi, and grok).

## Busy-guard and composer guard

The daemon never injects into an in-use pane. Two checks run before every
injection, dispatched through `bin/fm-backend.sh` for the supervisor's own
backend (tmux or herdr; see "Auto-discovered supervisor pane" below):

- **`pane_is_busy`** - the harness shows a busy footer (agent mid-turn) on tmux (shared with `fm-send.sh` via `bin/fm-tmux-lib.sh`); on herdr, tries the native `agent.get`-backed busy state first, trusts only `busy` outright, and corroborates every non-`busy` verdict with the same regex-over-capture reader.
- **`pane_input_pending`** - the composer holds real unsubmitted text (a
  human's half-typed line, or a previous injection whose Enter was swallowed).
  On tmux, the cursor-line detector **strips the harness's composer box
  borders first**, so an idle *bordered* composer (claude draws `│ > … │`) is
  correctly read as empty, not pending. Without this, every idle claude pane
  looked like pending input and the daemon deferred 100% of escalations
  (incident afk-invx-i5). `FM_COMPOSER_IDLE_RE` still overrides empty-composer
  matching after border stripping. On herdr, the equivalent ANSI-aware
  structural classifier (`fm_backend_herdr_composer_state`,
  docs/herdr-backend.md) plays the same role.

Either condition defers the injection; the buffered escalation survives in
`state/.subsuper-escalations` and is retried on the next housekeeping tick. In
afk mode the composer guard is belt-and-suspenders (no human is typing), but it
protects against the race window between the captain returning and their
message landing, and against the daemon's own previous injection sitting unsent.

**Max-defer escape (an escalation must never rot behind one broken channel).**
This paragraph group is the one owner of the escape contract.
If anything stays buffered past `FM_MAX_DEFER_SECS` (default 300), the daemon attempts one normal flush, which still requires an idle pane and empty composer.
If that submit cannot be confirmed, the pane channel itself may be the fault (incident afk-escalate-channel: a composer false-positive deferred every escalation for 3.5 hours, including the captain's own emailed approval), so the daemon stops relying on it and does three things:

1. **Emails the same digest out of band** (`oob_deliver` in `bin/fm-supervise-daemon.sh`).
   It sends only the buffered digest, only to the configured `FM_MAIL_CAPTAIN` address(es), from `FM_MAIL_INTAKE`, through the mail tool `fmm_resolve_axi` resolves, and only when mail mode is on with `FM_MAIL_SEND=1`.
   It fails closed on anything else (malformed address, unresolved tool, `FM_OOB_MAIL=0`) and records why.
   It is rate-limited to one attempt per `FM_OOB_MIN_INTERVAL_SECS` (default 1800), counting failed attempts because a failed send may still have gone out, and never re-sends a digest whose content was already emailed.
   The buffer is kept, so the terminal still gets the digest once the pane recovers.
2. **Writes `state/.subsuper-inject-wedged`**, recording the wedge age, the out-of-band outcome, and the undelivered items, plus an ERROR log line and a tmux status-line flash.
3. **Rides firstmate's next fleet action**: `bin/fm-guard.sh` prints a bordered alarm for a live marker, independent of in-flight tasks and of away mode, so a wedge cannot hide behind an idle operator.
   Handle the listed items, then remove the marker; a successful delivery also removes it.

**Why there is no forced last-resort submit.**
Typing and submitting regardless of the composer guard, then verifying, was considered and rejected.
When the guard is right, the composer holds real text: usually the captain's half-typed line from before they left.
A forced submit would merge the digest into that text and send it, so the captain's unfinished sentence goes out as if they had sent it, and because the line no longer starts with `FM_INJECT_MARK` firstmate would read it as the captain returning.
No post-submit check can undo that, and an absent captain would not see it happen.
The out-of-band email reaches the same reader without that risk, so the guard stays strict and the escape goes around it instead.

## Submit model

The digest is typed **once** (`send-keys -l` on tmux, `pane send-text` on
herdr - both literal, non-submitting sends), then submitted with Enter and
**verified** through the selected backend's submit primitive.
Enter is retried (Enter only, never a retype) until the backend confirms the
submit landed.
For tmux that confirmation is a cleared composer, using the same corrected,
border-aware detector as the composer guard.
For herdr, normal idle-baseline submits are confirmed by native agent-state showing a real turn started; the ANSI-aware composer classifier remains the pre-injection guard and conservative fallback for non-idle or unreadable baselines.
A bordered-empty or ghost-only composer is recognized as empty where that backend uses composer confirmation, rather than mistaken for a swallowed Enter.
`fm-send.sh` uses the same primitive and exits non-zero
when a steer's Enter is positively swallowed, so firstmate learns an instruction
did not land instead of leaving it unsubmitted.

## Classification policy

The daemon wraps `fm-watch.sh`, runs the watcher as a child, classifies each
wake reason in bash, and self-handles the routine majority without consuming a
firstmate turn.
Only captain-relevant events escalate to firstmate's context, and even then as
one pre-read, single-line, batched digest.
The classification predicates (the captain-relevant verb set, the signal/stale
tests, and the fleet-scan) live in the shared `bin/fm-classify-lib.sh`, the same
library the always-on watcher uses for its own triage when afk is off, so the two
modes apply one identical policy. While `state/.afk` exists the daemon owns the
watcher, so the watcher reverts to one-shot and lets the daemon do the triage -
the two never run their triage at the same time.

Classify each wake this way:

- `signal` whose status content has no captain-relevant verb
  (`done:|needs-decision:|blocked:|failed:|PR ready|checks green|ready in branch|merged`)
  -> self-handle. Captain-relevant verb -> escalate.
- `check` -> always escalate. Check scripts print only when firstmate should wake.
- `stale` with a terminal status -> escalate. Non-terminal stale is transient:
  record a marker and self-handle. If the pane is still idle past
  `FM_STALE_ESCALATE_SECS` (default 240s), housekeeping escalates it as a
  possible wedge. This bounds wedge-detection latency to the threshold plus a
  tick: a delay, never a loss. Healthy crewmates are autonomous and do not wait
  on firstmate mid-task.
- `heartbeat` -> self-handle. The daemon runs its own cheap bash fleet scan
  every `FM_HEARTBEAT_SCAN_SECS` (default 300s) as the catch-all for a
  captain-relevant status line the per-wake classifier might miss.
- Unknown reason, or any uncertainty -> escalate fail-safe.
- `check` reporting `mail-request <req>` from the mail-mode poll -> **captain mail**: escalate and flush immediately, bypassing the batch window, as an item starting `CAPTAIN MAIL`.
  The captain is speaking, so it must not sit behind a 90-second batch.
  The daemon does not clear `state/.afk` itself: injection is presence-gated on that flag, so clearing it would silence the channel carrying the mail to firstmate.
  Firstmate handles a `CAPTAIN MAIL` item first, through `fm-mail-respond`, with mail mode's own authority limits.
  It stays afk: an email is the channel an away captain uses, and only a real terminal message is the return signal.

Escalations are buffered up to `FM_ESCALATE_BATCH_SECS` (default 90s; 0 =
immediate) and flushed as one single-line digest prefixed with the sentinel
marker, carrying pre-read status summaries and a recommended action.
The single-line format makes the submission unambiguous across harnesses, and
the marker lets firstmate distinguish it from a real captain message.

## Injection hardening

- **Single-line digest** - embedded newlines are collapsed to a literal
  separator before injection, so submission is unambiguous regardless of
  harness.
- **Composer guard on the supervisor pane** - before injecting, the daemon
  checks both `pane_is_busy` (harness busy footer means agent mid-turn) and
  `pane_input_pending` (real unsubmitted text on the cursor line means human
  mid-typing or previous injection with swallowed Enter). Either condition
  defers injection and preserves the buffer for retry. The daemon never merges
  its digest into the captain's half-typed line.
- The composer detector, shared with `fm-send.sh` in `bin/fm-tmux-lib.sh`, drops
  dim/faint ghost text, then strips harness composer box borders, so a ghost-only
  or idle bordered composer such as claude's `│ > ... │` reads as empty, not
  pending. Without these filters, idle bordered composers and dim ghost
  suggestions can look like pending input and stall supervision. `FM_COMPOSER_IDLE_RE`
  still overrides empty-composer matching after dim-ghost and border stripping,
  and `FM_BUSY_REGEX` overrides busy footers.
- **Max-defer escape** - see "Max-defer escape" under "Busy-guard and composer guard" above: retry once, then email the captain out of band, write the wedge marker, and alarm through `bin/fm-guard.sh`.
- **Verified type-once submit model** - the digest is typed once (`send-keys -l`
  on tmux, `pane send-text` on herdr), then submitted with Enter and verified.
  Enter is retried, Enter only and never a retype, until the backend submit
  primitive reports `empty` as its caller-facing success verdict.
  For tmux that verdict means the dim-ghost-aware and border-aware composer
  cleared.
  For herdr's normal idle-baseline path it means native agent-state observed a real turn start; herdr uses the ANSI-aware structural classifier for the pre-injection composer guard and fallback paths.
  This lets ghost-only or bordered-empty composers count as empty where a composer read is the active confirmation signal.
- **Marker strip** - `strip_injection_marker` removes the sentinel prefix before
  classification or relay, so the digest text firstmate sees is clean.
- **Portable singleton lock** - the daemon uses the repo's portable lock helper
  (`fm-wake-lib.sh`) instead of `flock`, which is absent on macOS.
- **Dedupe across signal/stale/scan** - `classify_signal` and `classify_stale`
  both check the seen-status marker before escalating, so a status escalated by
  one path is not re-escalated by another in the same digest.
- **Auto-discovered supervisor pane** - the daemon resolves its own BACKEND
  (tmux vs herdr) and TARGET independently, mirroring
  `bin/fm-backend.sh`'s own runtime auto-detection. Backend: `FM_SUPERVISOR_BACKEND`
  override, then `$TMUX_PANE` set (tmux), then `$HERDR_ENV=1` with
  `$HERDR_PANE_ID` present (herdr), then a tmux fallback. Target:
  `FM_SUPERVISOR_TARGET` override (a tmux target or a herdr
  `"<session>:<pane-id>"` target), then `$TMUX_PANE`, then
  `"${HERDR_SESSION:-default}:${HERDR_PANE_ID}"` under herdr, then a
  `firstmate:0` fallback with a warning. Both resolution sources are logged at
  startup so a wrong-but-resolving fallback is detectable. Other runtime
  backends, including zellij, orca, and cmux, are not yet supported as
  supervisor backends; the daemon refuses loudly at startup instead of
  misapplying tmux primitives to a pane that isn't one
  (docs/herdr-backend.md "Away-mode daemon: herdr supervisor-pane support").

## Reliability properties

These properties must hold:

- Nothing is lost. The durable queue plus `fm-wake-drain.sh` recover any missed
  or crashed injection.
- Wedge detection is bounded-latency, not lossy.
- The catch-all scan backs up the keyword classifier.
- The daemon preserves a single-instance portable lock, crash-loop backoff,
  a pane-gone guard, and a signal-trapped shutdown that flushes buffered
  escalations before exit.

`FM_INJECT_SKIP` (default `heartbeat`) force-self-handles matching kinds,
overriding classification.
Use it sparingly.
