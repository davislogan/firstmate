---
name: secondmate-provisioning
description: >-
  Agent-only reference for persistent secondmate setup and retirement.
  Use when creating, seeding, validating, launching, recovering, handing backlog to, pushing inherited config into, or retiring a secondmate home, or when editing data/secondmates.md.
  Covers home leases, transactional seeding, project clone restrictions, secondmate harness pins, inherited config push, idle charter, handoff helper, and teardown safety.
user-invocable: false
metadata:
  internal: true
---

# secondmate-provisioning

Use this reference before creating, seeding, validating, launching, handing backlog to, recovering, pushing inherited config into, or retiring a persistent secondmate, and before editing `data/secondmates.md`.

Keep the always-inline routing rules in `AGENTS.md` authoritative: route by natural-language `scope:`, local-only projects stay with the main firstmate unless a secondmate home holds them in place, and secondmates are idle by default.

## Routing table

`data/secondmates.md` has one line per persistent domain supervisor:

```markdown
- <id> - <charter summary> (home: <absolute-home-path>; scope: <natural-language responsibility>; projects: <project-a>, <project-b>; added <date>)
```

The `scope:` field is used during intake.
The `projects:` field is a non-exclusive clone list, not ownership.

### Per-route model pin

A route may end with an optional `; model: <model>` field after the added date:

```markdown
- <id> - <charter summary> (home: <path>; scope: <scope>; projects: <a>, <b>; added <date>; model: <model>)
```

This section is the one owner of the per-route model contract; other docs cross-reference it.
It exists because the model is sometimes a safety requirement, not a preference: a home whose crews would be parked by a newer model's safeguards must keep running on the model it was pinned to.
`bin/fm-spawn.sh` re-reads the field from `data/secondmates.md` on every `--secondmate` spawn, so the pin survives recovery, restart, the bootstrap liveness sweep, and `/updatefirstmate`, none of which pass `--model`.
Model precedence for a `--secondmate` spawn, highest first:

1. An explicit per-spawn `--model`.
2. The route's `model:` field.
3. The model token in `config/secondmate-harness` (described below).
4. The harness's own default.

The route pin applies even when the spawn passes an explicit harness, because it belongs to the home rather than to the launch path; a raw launch command carries no model placeholder, so no pin can apply to it.
It never affects crewmate or scout model resolution.
Do not pin `default`: an account-level setting can make a harness's default model change under you, so `default` is not a pin and the helper refuses it.
Set, read, or clear a pin with `bin/fm-home-seed.sh model <id> [<model>|-]`; seeding with `FM_SECONDMATE_MODEL=<model>` sets it at creation, and re-seeding an existing id keeps its pin unless that variable is set.
`bin/fm-home-seed.sh validate` refuses a malformed `model:` token.

## Charter and seed

Scaffold a secondmate charter with:

```sh
bin/fm-brief.sh <id> --secondmate <project>...
```

The scaffold writes a charter brief instead of a task brief.
Set `FM_SECONDMATE_CHARTER='<charter>'` to fill the charter text and `FM_SECONDMATE_SCOPE='<scope>'` when the routing scope differs.
If you scaffold without `FM_SECONDMATE_CHARTER`, replace the `{TASK}` placeholder before seeding.
Keep the charter focused on the persistent responsibility, available project clones, escalation back to the main firstmate status file, and the requests-from-main-firstmate contract.
The scaffold's definition of done encodes the idle-by-default contract: on startup the secondmate reconciles only its own in-flight work and then waits for routed tasks, never self-initiating a survey or audit.
Preserve that wording when filling the charter, including the marker rule that marked supervisor requests return through status or a doc pointer while unmarked captain messages stay conversational.

Provision the persistent home and registry entry after the charter is filled:

```sh
bin/fm-home-seed.sh <id> <home|-> <project>...
```

`-` durably leases a fresh firstmate worktree via `treehouse get --lease` under the secondmate id.
The lease survives with no live process and is never recycled by later `treehouse get` or `prune`.
The slot stays reserved across restarts until the lease is released.
Release happens only on explicit retirement or seed rollback, never on routine restart or recovery.

`bin/fm-home-seed.sh` copies the charter into the secondmate home as `data/charter.md`.
`bin/fm-spawn.sh --secondmate` launches it through the secondmate harness path, resolving `config/secondmate-harness` -> `config/crew-harness` -> the primary's own harness unless an explicit per-spawn harness override is passed.

`config/secondmate-harness` may also pin a concrete model and effort for the secondmate agent, in the SAME file rather than a new one: the format is a single whitespace-separated line `<harness> [<model>] [<effort>]`, with only the first non-empty, non-comment line parsed.
A bare `<harness>` (today's format, e.g. `claude`) behaves exactly as before - harness only, no model/effort flag - so this is fully backward-compatible.
`bin/fm-harness.sh secondmate-model` and `bin/fm-harness.sh secondmate-effort` print the optional 2nd/3rd tokens (empty when absent, or when the file is absent/`default`/harness-only); they read only `config/secondmate-harness`, never `config/crew-harness`, which stays a bare adapter name.
For a `--secondmate` spawn, `bin/fm-spawn.sh` populates `MODEL`/`EFFORT` from those tokens only when the harness itself came from the secondmate config path for that spawn.
An explicit per-spawn `--harness` flag, positional harness arg, or raw launch command starts clean on model and effort too, unless the caller also passes explicit `--model` or `--effort`.
When the file's tokens do apply, an explicit per-spawn `--model` or `--effort` flag always wins over the file's token for that axis.
A route's own `model:` pin also outranks the file's model token; see "Per-route model pin" above.
Because this resolves from the file on every spawn, the pin is durable across every respawn (recovery, `/updatefirstmate`, restart) exactly like the harness axis itself - e.g. `config/secondmate-harness` containing `claude opus` keeps a secondmate pinned to Opus even if the primary's own default model later changes.
This is secondmate-only: crewmate/scout model resolution is untouched by this file.

Before launch, `fm-spawn.sh --secondmate` locally fast-forwards the home to the primary firstmate checkout's current default-branch commit when it is safe; dirty, diverged, or in-flight homes launch unchanged with a warning.
The same launch also propagates the primary's declared inheritable local config, currently `config/crew-dispatch.json`, `config/crew-harness`, and `config/backlog-backend`, into the secondmate home's `config/`.
`config/secondmate-harness` is not inherited because it is only the primary's knob for launching secondmate agents.
For already-live secondmates, use `bin/fm-config-push.sh` to push a mid-session inherited-config change without running the tracked-file fast-forward or nudging the agents.
It uses the same live-home discovery and propagation helper as bootstrap and reports each item as `pushed`, `unchanged`, `skipped`, or `error`.
`bin/fm-home-seed.sh` refuses to copy a missing or placeholder charter.

Direct seed without a preexisting brief requires `FM_SECONDMATE_CHARTER`.
Run `bin/fm-home-seed.sh validate` when checking registry integrity; it refuses duplicate ids, duplicate homes, and nested or overlapping homes.

Seeding is transactional.
If validation, cloning, no-mistakes initialization, or registry update fails, generated briefs, new homes, new project clones, and registry edits are rolled back.

Secondmate project lists may include `no-mistakes` and `direct-PR` projects, which seeding clones from their origin.
A `local-only` project has no remote to clone and its local merges must land where the primary sees them, so seeding never clones one.
It is accepted only in place: the secondmate home's `projects/<project>` already exists as a work tree of the same repository as the primary's `projects/<project>`, recognized by a matching resolved git common dir, with no origin required.
The usual shape is both entries being symlinks to one live checkout that the live system executes from; create that symlink in the secondmate home before seeding.
Any other `local-only` project stays with the main firstmate; `bin/fm-home-seed.sh`'s header lists the exact accepted and refused cases.
For `no-mistakes` projects, seeding initializes only projects newly cloned into a secondmate home and refuses to mutate a preexisting clone that is not already initialized.

## Backlog handoff

When a secondmate is created for a domain, existing main-backlog items that fall under its scope should become its work instead of staying stranded in the main backlog.
Scope-matching is firstmate's judgment against the secondmate's natural-language scope, not a keyword rule.
Read `data/backlog.md`, pick queued items that fit the new scope, and move them with:

```sh
bin/fm-backlog-handoff.sh <secondmate-id> <item-key>...
```

After seeding, run this handoff for the new secondmate's in-scope queued items.
The helper resolves the secondmate home from `data/secondmates.md` and mechanically moves each named item from the main `data/backlog.md` into the secondmate home's `data/backlog.md`.
It preserves the line and its section, so the item is neither duplicated nor lost.
It refuses `## In flight` entries because active task ownership also lives in tmux and `state/`.
It is idempotent; an item already in the secondmate backlog is skipped.
It refuses any destination that is not a genuine seeded firstmate home with safe operational directories and a matching `.fm-secondmate-home` marker, so a move can never land in a project.
Do not hand off `local-only` items unless the secondmate home holds that project in place, as described under "Charter and seed" above.

## Recovery

For `kind=secondmate` meta with no window, treat the secondmate as a dead persistent direct report and respawn it with:

```sh
bin/fm-spawn.sh <id> --secondmate
```

Use the recorded `home=` in meta.
If meta is missing but `data/secondmates.md` still registers the secondmate, respawn from the registry entry and its persistent on-disk home.
Respawn re-resolves the secondmate harness from current config, uses the same guarded pre-launch sync, and re-propagates inheritable config, so recovered secondmates converge to the primary firstmate version and local dispatch, crew-harness, and backlog-backend settings whenever their home can be cleanly fast-forwarded.
If the secondmate is already running and only inherited config changed, prefer `bin/fm-config-push.sh` over respawning.

Do not reconstruct a secondmate's whole tree from the main home.
The main firstmate reconciles only direct reports.
Each secondmate is a firstmate in its own home, so it runs recovery on startup and reconciles its own crewmates.
A secondmate's recovery reconciles only work that is already its own and then idles.
It never initiates a survey or audit during recovery.

## Retirement and teardown

A secondmate is persistent by default.
An empty queue is healthy and does not trigger teardown.
Run `bin/fm-teardown.sh <id>` for `kind=secondmate` only when the captain or main firstmate explicitly decides to retire that persistent supervisor.

The safety check is the secondmate's own home.
Teardown refuses while its `state/*.meta` contains in-flight work.
When safe, teardown kills the direct tmux window, removes the `data/secondmates.md` route, clears the main home metadata, and removes the retired secondmate home.
Removing a leased home releases its durable treehouse lease via `treehouse return`, so the pool slot is freed for reuse rather than left leased forever.
A plain-clone home with no pool slot is simply removed.
If `treehouse return` fails for a leased home, teardown stops with state intact rather than raw-removing the directory and hiding a held lease.

With `--force`, teardown is the explicit discard path.
It kills child windows, discards child work and state inside the secondmate home, removes the route, releases the lease, and removes the retired secondmate home.
Never use `--force` unless the captain explicitly said to discard the work.
