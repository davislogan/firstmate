#!/usr/bin/env bash
# Tests for the per-route secondmate model pin and the absolute harness-binary
# resolution in bin/fm-spawn.sh.
#
# The per-route pin is an optional "; model: <model>" field on a
# data/secondmates.md route (secondmate-provisioning skill, "Per-route model
# pin"). The guarantees under test:
#   P) Precedence for a --secondmate spawn, at every level: explicit --model >
#      route model > config/secondmate-harness model token > harness default.
#      The route pin applies even with an explicit --harness, and a route that
#      says "default" is ignored with a warning rather than treated as a pin.
#   R) Durability: the bootstrap liveness sweep respawns a dead secondmate with
#      no --model flag, and the respawned home still launches on its route pin
#      while an unpinned sibling keeps the config/secondmate-harness token.
#   C) Crewmate and scout model resolution is unchanged: a ship or scout spawn
#      never reads the route pin or the secondmate-harness token, even when its
#      task id matches a pinned route.
#   S) Registry: fm-home-seed.sh model sets, reads, replaces, and clears a pin
#      while leaving every other byte of the registry alone, refuses "default"
#      and malformed tokens, and validate refuses a malformed pin on disk.
#   B) Binary resolution: a template launch names the harness by absolute path,
#      and a harness binary missing from PATH fails the spawn loudly before any
#      endpoint is created, instead of dying silently in the pane.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
fm_git_identity fmtest fmtest@example.com
TMP_ROOT=$(fm_test_tmproot fm-secondmate-model-pin)
export FM_BACKEND=tmux

meta_field() { grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2-; }

# A tmux stub that captures every literal `send-keys -l <cmd>` into
# $FM_FAKE_LAUNCH_LOG, logs new-window/kill-window into $FM_TMUX_CALL_LOG when
# set, answers #{pane_current_path} from $FM_FAKE_PANE_PATH for crew spawns, and
# answers #{pane_current_command} from $FM_TEST_PANE_CMD for the liveness probe.
make_tmux() {
  local fakebin
  fakebin=$(fm_fakebin "$1")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
  *"#{pane_current_command}"*) printf '%s\n' "${FM_TEST_PANE_CMD:-zsh}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  new-window|kill-window)
    [ -z "${FM_TMUX_CALL_LOG:-}" ] || printf '%s\n' "$*" >> "$FM_TMUX_CALL_LOG"
    exit 0 ;;
  send-keys)
    if [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
      prev=
      for a in "$@"; do
        [ "$prev" != "-l" ] || printf '%s\n' "$a" >> "$FM_FAKE_LAUNCH_LOG"
        prev=$a
      done
    fi
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# A minimal seeded secondmate home that validate_firstmate_home_for_spawn accepts.
make_seeded_home() {
  local home=$1 id=$2
  mkdir -p "$home/bin" "$home/data" "$home/state" "$home/config" "$home/projects"
  printf '# Firstmate\n' > "$home/AGENTS.md"
  printf '%s\n' "$id" > "$home/.fm-secondmate-home"
  printf 'charter\n' > "$home/data/charter.md"
}

# add_route <world> <id> <home> [model]: append one registry line, with an
# optional trailing per-route model field.
add_route() {
  local w=$1 id=$2 home=$3 model=${4:-} field=
  [ -z "$model" ] || field="; model: $model"
  mkdir -p "$w/home/data"
  printf -- '- %s - %s charter (home: %s; scope: %s work; projects: alpha; added 2026-01-01%s)\n' \
    "$id" "$id" "$home" "$id" "$field" >> "$w/home/data/secondmates.md"
}

new_world() {
  local w="$TMP_ROOT/$1"
  mkdir -p "$w/home/state" "$w/home/data" "$w/home/config"
  printf '%s\n' "$w"
}

# spawn_sm <world> <id> <launchlog> [extra fm-spawn.sh args...]: a --secondmate
# spawn of a registered home, exactly the shape recovery and bootstrap use.
spawn_sm() {
  local w=$1 id=$2 launchlog=$3 fakebin
  shift 3
  fakebin=$(make_tmux "$w/tmux-$id")
  : > "$launchlog"
  PATH="$fakebin:$BASE_PATH" TMUX='' CLAUDECODE=1 \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$w/home" \
    FM_STATE_OVERRIDE="$w/home/state" FM_DATA_OVERRIDE="$w/home/data" \
    FM_PROJECTS_OVERRIDE="$w/home/projects" FM_CONFIG_OVERRIDE="$w/home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_LAUNCH_LOG="$launchlog" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$@" --secondmate
}

# ===========================================================================
# P) precedence, one row per level
# ===========================================================================
#   <label>^<secondmate-harness file or ->^<route model or ->^<extra spawn args>^<expect model>^<expect harness>
test_precedence_table() {
  local label sm_file route extra exp_model exp_harness n w sm launchlog out status meta launch
  local -a args
  n=0
  while IFS='^' read -r label sm_file route extra exp_model exp_harness; do
    [ -n "$label" ] || continue
    n=$((n + 1))
    w=$(new_world "prec-$n")
    sm="$w/sm"
    launchlog="$w/launch.log"
    make_seeded_home "$sm" sm
    [ "$sm_file" = - ] || printf '%s\n' "$sm_file" > "$w/home/config/secondmate-harness"
    if [ "$route" = - ]; then add_route "$w" sm "$sm"; else add_route "$w" sm "$sm" "$route"; fi
    args=()
    # shellcheck disable=SC2206  # the table's extra-args column is deliberately word-split
    [ -z "$extra" ] || args=($extra)
    out=$(spawn_sm "$w" sm "$launchlog" "${args[@]}" 2>&1); status=$?
    expect_code 0 "$status" "$label: spawn should succeed"$'\n'"$out"
    meta="$w/home/state/sm.meta"
    [ "$(meta_field "$meta" model)" = "$exp_model" ] \
      || fail "$label: meta model '$(meta_field "$meta" model)', expected '$exp_model'"
    [ "$(meta_field "$meta" harness)" = "$exp_harness" ] \
      || fail "$label: meta harness '$(meta_field "$meta" harness)', expected '$exp_harness'"
    launch=$(cat "$launchlog")
    if [ "$exp_model" = default ]; then
      assert_not_contains "$launch" "--model" "$label: launch must not carry --model"
    else
      assert_contains "$launch" "--model '$exp_model'" "$label: launch did not carry --model $exp_model"
    fi
    case "$label" in
      *"route default"*) assert_contains "$out" "pins model 'default', which is not a pin" "$label: no warning for a 'default' route pin" ;;
    esac
  done <<'ROWS'
L4 nothing set -> harness default^claude^-^^default^claude
L3 secondmate-harness token only^claude opus-5-5^-^^opus-5-5^claude
L2 route pin outranks the token^claude opus-5-5^opus-5^^opus-5^claude
L2 route pin with no secondmate-harness file^-^opus-5^^opus-5^claude
L2 route pin survives an explicit harness^claude opus-5-5^opus-5^--harness claude^opus-5^claude
L1 explicit --model outranks the route pin^claude opus-5-5^opus-5^--model sonnet^sonnet^claude
L1 explicit --model with no route pin^claude opus-5-5^-^--model sonnet^sonnet^claude
route default is ignored and falls through^claude opus-5-5^default^^opus-5-5^claude
ROWS
  pass "P precedence: explicit --model > route pin > secondmate-harness token > harness default, at every level"
}

# A route that mentions model: but does not parse to a valid pin fails the
# spawn closed: no endpoint, no meta, and a fix pointer.
test_malformed_route_pin_fails_closed() {
  local route n w sm launchlog calls fakebin out status
  n=0
  for route in 'model:claude-opus-5' 'model: opus 5' 'model: ' 'mode: x'; do
    n=$((n + 1))
    w=$(new_world "malformed-$n")
    sm="$w/sm"
    make_seeded_home "$sm" sm
    printf 'claude claude-opus-5-5\n' > "$w/home/config/secondmate-harness"
    printf -- '- sm - sm charter (home: %s; scope: sm work; projects: alpha; added 2026-01-01; %s)\n' \
      "$sm" "$route" > "$w/home/data/secondmates.md"
    fakebin=$(make_tmux "$w/tmux")
    launchlog="$w/launch.log"; calls="$w/calls.log"
    : > "$launchlog"; : > "$calls"
    out=$(PATH="$fakebin:$BASE_PATH" TMUX='' CLAUDECODE=1 \
      FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$w/home" \
      FM_STATE_OVERRIDE="$w/home/state" FM_DATA_OVERRIDE="$w/home/data" \
      FM_PROJECTS_OVERRIDE="$w/home/projects" FM_CONFIG_OVERRIDE="$w/home/config" \
      FM_SPAWN_NO_GUARD=1 FM_FAKE_LAUNCH_LOG="$launchlog" FM_TMUX_CALL_LOG="$calls" \
      "$ROOT/bin/fm-spawn.sh" sm --secondmate 2>&1); status=$?
    [ "$status" -ne 0 ] || fail "'$route': a malformed route pin must fail the spawn"
    assert_contains "$out" "route for sm has a malformed model pin" "'$route': no malformed-pin error"$'\n'"$out"
    assert_contains "$out" "bin/fm-home-seed.sh model sm <model>" "'$route': error did not point at the fix"
    [ ! -s "$calls" ] || fail "'$route': no endpoint may be created: $(cat "$calls")"
    [ ! -s "$launchlog" ] || fail "'$route': no launch may be sent: $(cat "$launchlog")"
    assert_absent "$w/home/state/sm.meta" "'$route': a malformed pin must not write meta"
    seed "$w/home/data" model sm claude-opus-5 || fail "'$route': the suggested fix command failed"
    assert_grep "added 2026-01-01; model: claude-opus-5)" "$w/home/data/secondmates.md" "'$route': the fix did not rewrite the tail"
  done
  pass "P a malformed route pin fails the secondmate spawn closed before any endpoint or meta"
}

# A "model:" in the charter summary or scope prose is never read as a pin: with
# no trailing field the route spawns on the default and validates; with a valid
# trailing field the pin still applies.
test_prose_model_is_not_a_pin() {
  local tail exp n w sm launchlog out status meta
  n=0
  for tail in ')^default' '; model: claude-opus-5)^claude-opus-5'; do
    n=$((n + 1))
    exp=${tail#*^}; tail=${tail%^*}
    w=$(new_world "prose-$n")
    sm="$w/sm"
    make_seeded_home "$sm" sm
    printf -- '- sm - Owns model: training and eval (home: %s; scope: model: training work; projects: alpha; added 2026-01-01%s\n' \
      "$sm" "$tail" > "$w/home/data/secondmates.md"
    launchlog="$w/launch.log"
    out=$(spawn_sm "$w" sm "$launchlog" 2>&1); status=$?
    expect_code 0 "$status" "prose model ($exp): spawn should succeed"$'\n'"$out"
    meta="$w/home/state/sm.meta"
    [ "$(meta_field "$meta" model)" = "$exp" ] \
      || fail "prose model: meta model '$(meta_field "$meta" model)', expected '$exp'"
    seed "$w/home/data" validate || fail "prose model ($exp): route should validate"
    [ "$(seed "$w/home/data" model sm)" = "$([ "$exp" = default ] || printf '%s' "$exp")" ] \
      || fail "prose model ($exp): model subcommand read the wrong pin"
  done
  pass "P a 'model:' in charter or scope prose is ignored; only the trailing field is a pin"
}

# ===========================================================================
# R) the bootstrap liveness sweep respawns with no --model and keeps the pin
# ===========================================================================

# make_toolchain <dir>: stubs bin/fm-bootstrap.sh's read-only diagnostics need
# (mirrors tests/fm-secondmate-liveness.test.sh), minus tmux.
make_toolchain() {
  local fakebin
  fakebin=$(fm_fakebin "$1")
  fm_fake_exit0 "$fakebin" node gh gh-axi chrome-devtools-axi lavish-axi
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = get ] && [ "${2:-}" = --help ]; then
  printf '%s\n' 'Usage: treehouse get [--lease]'
fi
exit 0
SH
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" != --version ] || printf '%s\n' 'no-mistakes version v1.31.2 (fake)'
exit 0
SH
  chmod +x "$fakebin/treehouse" "$fakebin/no-mistakes"
  printf '%s\n' "$fakebin"
}

# add_dead_secondmate <world> <id>: a registered home plus a kind=secondmate meta
# whose endpoint the probe will read as a bare shell (dead).
add_dead_secondmate() {
  local w=$1 id=$2
  make_seeded_home "$w/$id" "$id"
  {
    printf 'window=firstmate:fm-%s\n' "$id"
    printf 'kind=secondmate\n'
    printf 'harness=claude\n'
    printf 'home=%s\n' "$w/$id"
    printf 'model=default\n'
  } > "$w/home/state/$id.meta"
}

test_bootstrap_respawn_keeps_route_pin() {
  local w fb tmuxfb calls launchlog out launches
  w=$(new_world bootstrap-respawn)
  touch "$w/home/state/.last-watcher-beat"
  # The global token is the "wrong" model for biochem; only its route pin saves it.
  printf 'claude claude-opus-5-5\n' > "$w/home/config/secondmate-harness"
  add_dead_secondmate "$w" biochem
  add_dead_secondmate "$w" fmp
  add_route "$w" biochem "$w/biochem" claude-opus-5
  add_route "$w" fmp "$w/fmp"
  fb=$(make_toolchain "$w/tools"); tmuxfb=$(make_tmux "$w/tmux")
  calls="$w/calls.log"; launchlog="$w/launch.log"
  : > "$calls"; : > "$launchlog"

  out=$(PATH="$tmuxfb:$fb:$BASE_PATH" TMUX='' FM_BACKEND=tmux FM_HOME="$w/home" CLAUDECODE=1 \
    FM_TEST_PANE_CMD=zsh FM_TMUX_CALL_LOG="$calls" FM_FAKE_LAUNCH_LOG="$launchlog" \
    "$ROOT/bin/fm-bootstrap.sh" 2>&1)

  assert_contains "$out" "SECONDMATE_LIVENESS: secondmate biochem: respawned" "biochem was not respawned by the sweep"$'\n'"$out"
  assert_contains "$out" "SECONDMATE_LIVENESS: secondmate fmp: respawned" "fmp was not respawned by the sweep"$'\n'"$out"
  [ "$(meta_field "$w/home/state/biochem.meta" model)" = claude-opus-5 ] \
    || fail "bootstrap respawn: biochem meta model '$(meta_field "$w/home/state/biochem.meta" model)', expected its route pin claude-opus-5"
  [ "$(meta_field "$w/home/state/fmp.meta" model)" = claude-opus-5-5 ] \
    || fail "bootstrap respawn: unpinned fmp should keep the secondmate-harness token"
  launches=$(cat "$launchlog")
  assert_contains "$launches" "FM_HOME='$w/biochem'" "biochem launch was not captured"
  printf '%s\n' "$launches" | grep -F "FM_HOME='$w/biochem'" | grep -F -- "--model 'claude-opus-5' " >/dev/null \
    || fail "bootstrap respawn: biochem relaunched without its pinned --model claude-opus-5"$'\n'"$launches"
  printf '%s\n' "$launches" | grep -F "FM_HOME='$w/fmp'" | grep -F -- "--model 'claude-opus-5-5' " >/dev/null \
    || fail "bootstrap respawn: fmp relaunched without the secondmate-harness token"$'\n'"$launches"
  pass "R a bootstrap liveness respawn (no --model) relaunches each home on its route pin, unpinned homes on the token"
}

# ===========================================================================
# C) crewmate and scout resolution is unchanged
# ===========================================================================
test_crew_and_scout_ignore_route_pin() {
  local w id kind proj wt fakebin launchlog meta launch flag
  w=$(new_world crew-unchanged)
  printf 'claude opus-5-5\n' > "$w/home/config/secondmate-harness"
  printf 'claude\n' > "$w/home/config/crew-harness"
  for kind in ship scout; do
    # The task id deliberately matches a pinned route, the worst case for leakage.
    id="pinned-$kind"
    add_route "$w" "$id" "$w/elsewhere-$kind" opus-5
    proj="$w/project-$kind"; wt="$w/wt-$kind"
    fm_git_worktree "$proj" "$wt" "wt-$kind"
    mkdir -p "$w/home/data/$id"
    printf 'brief\n' > "$w/home/data/$id/brief.md"
    fakebin=$(make_tmux "$w/tmux-$kind")
    launchlog="$w/launch-$kind.log"; : > "$launchlog"
    flag=()
    [ "$kind" = ship ] || flag=(--scout)
    PATH="$fakebin:$BASE_PATH" TMUX="fake,1,0" CLAUDECODE=1 \
      FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$w/home" \
      FM_STATE_OVERRIDE="$w/home/state" FM_DATA_OVERRIDE="$w/home/data" \
      FM_PROJECTS_OVERRIDE="$w/home/projects" FM_CONFIG_OVERRIDE="$w/home/config" \
      FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" FM_FAKE_LAUNCH_LOG="$launchlog" \
      "$ROOT/bin/fm-spawn.sh" "$id" "$proj" "${flag[@]}" >/dev/null 2>&1 \
      || fail "$kind spawn failed"
    meta="$w/home/state/$id.meta"
    [ "$(meta_field "$meta" kind)" = "$kind" ] || fail "$kind: unexpected kind '$(meta_field "$meta" kind)'"
    [ "$(meta_field "$meta" model)" = default ] || fail "$kind: model '$(meta_field "$meta" model)' leaked into a non-secondmate spawn"
    launch=$(cat "$launchlog")
    assert_not_contains "$launch" "--model" "$kind: launch must not carry --model"
    rm -rf "/tmp/fm-$id"
  done
  pass "C crewmate and scout spawns never read the route pin or secondmate-harness token"
}

# ===========================================================================
# S) registry writer and validation
# ===========================================================================
seed() { FM_DATA_OVERRIDE="$1" "$ROOT/bin/fm-home-seed.sh" "${@:2}"; }

test_registry_model_subcommand() {
  local w data reg orig out status
  w=$(new_world registry)
  data="$w/home/data"; reg="$data/secondmates.md"
  printf '# Secondmates\n' > "$reg"
  add_route "$w" biochem "$w/biochem"
  add_route "$w" fmp "$w/fmp"
  cp "$reg" "$w/orig"; orig="$w/orig"

  out=$(seed "$data" model biochem); status=$?
  expect_code 0 "$status" "reading an unset pin should succeed"
  [ -z "$out" ] || fail "an unset pin should print nothing, got '$out'"

  seed "$data" model biochem claude-opus-5 || fail "setting a pin failed"
  [ "$(seed "$data" model biochem)" = claude-opus-5 ] || fail "pin did not read back"
  assert_grep "added 2026-01-01; model: claude-opus-5)" "$reg" "pin was not written as the trailing field"
  seed "$data" model biochem claude-opus-5-5 || fail "replacing a pin failed"
  [ "$(grep -c 'model:' "$reg")" = 1 ] || fail "replacing a pin should leave exactly one model field"
  [ "$(seed "$data" model biochem)" = claude-opus-5-5 ] || fail "replaced pin did not read back"
  seed "$data" model biochem - || fail "clearing a pin failed"
  cmp -s "$orig" "$reg" || fail "set+replace+clear should leave the registry byte-identical"$'\n'"$(diff "$orig" "$reg")"

  seed "$data" model biochem default >/dev/null 2>&1 && fail "'default' must be refused as a pin"
  seed "$data" model biochem 'two words' >/dev/null 2>&1 && fail "a multi-word pin must be refused"
  seed "$data" model nobody opus >/dev/null 2>&1 && fail "pinning an unregistered id must fail"
  cmp -s "$orig" "$reg" || fail "refused pins must not touch the registry"

  # A rewrite that would leave the registry invalid is all-or-nothing.
  sed -i.bak 's/^\(- fmp .*added 2026-01-01\))$/\1; model:bad)/' "$reg"
  cp "$reg" "$w/broken"
  seed "$data" model biochem claude-opus-5 >/dev/null 2>&1 && fail "pinning must fail while another route is malformed"
  cmp -s "$w/broken" "$reg" || fail "a failed validation must leave the registry untouched"$'\n'"$(diff "$w/broken" "$reg")"
  cp "$orig" "$reg"

  seed "$data" validate || fail "a clean registry should validate"
  sed -i.bak 's/added 2026-01-01)$/added 2026-01-01; model: default)/' "$reg"
  out=$(seed "$data" validate 2>&1) && fail "validate must refuse a 'default' pin on disk"
  assert_contains "$out" "malformed per-route model pin" "validate gave no model-pin reason"
  pass "S fm-home-seed.sh model sets/reads/replaces/clears a pin byte-cleanly and refuses bad pins; validate checks pins"
}

# Re-seeding an existing route keeps its pin, and FM_SECONDMATE_MODEL sets one.
# write_registry is exercised in isolation by sourcing its definitions, because
# a full seed needs real project clones that the safety suite already covers.
# run_write_registry <reg> <data> <id> <home> <brief> [VAR=value...]: call the
# real write_registry with only fm-home-seed.sh's definitions loaded.
run_write_registry() {
  local reg=$1 data=$2 id=$3 home=$4 brief=$5
  shift 5
  (
    # shellcheck disable=SC2163  # the args are VAR=value pairs
    [ $# -eq 0 ] || export "$@"
    # shellcheck disable=SC1090  # load only the function definitions, not the dispatcher
    . <(sed -e '/^case "\${1:-}" in$/,$d' -e "s|^SCRIPT_DIR=.*|SCRIPT_DIR='$ROOT/bin'|" "$ROOT/bin/fm-home-seed.sh")
    # shellcheck disable=SC2034  # read by the sourced write_registry
    REG=$reg DATA=$data
    write_registry "$id" "$home" alpha "$brief"
  )
}

test_write_registry_preserves_pin() {
  local w data reg brief out
  w=$(new_world write-registry)
  data="$w/home/data"; reg="$data/secondmates.md"
  brief="$w/brief.md"
  printf '# Task\nGuard the bench.\n' > "$brief"
  add_route "$w" biochem "$w/biochem" claude-opus-5
  run_write_registry "$reg" "$data" biochem "$w/biochem" "$brief" || fail "write_registry failed"
  [ "$(grep -c '^- biochem ' "$reg")" = 1 ] || fail "re-seed duplicated the route"
  assert_grep "; model: claude-opus-5)" "$reg" "re-seed dropped the existing pin"
  run_write_registry "$reg" "$data" biochem "$w/biochem" "$brief" FM_SECONDMATE_MODEL=claude-opus-5-5 \
    || fail "write_registry with FM_SECONDMATE_MODEL failed"
  assert_grep "; model: claude-opus-5-5)" "$reg" "FM_SECONDMATE_MODEL did not set the pin"
  [ "$(grep -c 'model:' "$reg")" = 1 ] || fail "FM_SECONDMATE_MODEL should leave exactly one model field"
  out=$(FM_SECONDMATE_MODEL=default seed "$data" x - alpha 2>&1) && fail "seeding with FM_SECONDMATE_MODEL=default must fail"
  assert_contains "$out" "invalid FM_SECONDMATE_MODEL" "seed gave no reason for a bad FM_SECONDMATE_MODEL"

  # A malformed (intended) pin is never silently dropped by a re-seed.
  printf -- '- biochem - biochem charter (home: %s; scope: biochem work; projects: alpha; added 2026-01-01; model:claude-opus-5)\n' \
    "$w/biochem" > "$reg"
  cp "$reg" "$w/malformed"
  out=$(run_write_registry "$reg" "$data" biochem "$w/biochem" "$brief" 2>&1) && fail "re-seed over a malformed pin must fail"
  assert_contains "$out" "bin/fm-home-seed.sh model biochem <model>" "malformed re-seed did not point at the fix"$'\n'"$out"
  cmp -s "$w/malformed" "$reg" || fail "a refused re-seed must leave the registry untouched"
  out=$(seed "$data" biochem - alpha 2>&1) && fail "the seed command must refuse a re-seed over a malformed pin"
  assert_contains "$out" "malformed model pin" "seed command gave no malformed-pin reason"$'\n'"$out"
  cmp -s "$w/malformed" "$reg" || fail "a refused seed command must leave the registry untouched"
  run_write_registry "$reg" "$data" biochem "$w/biochem" "$brief" FM_SECONDMATE_MODEL=claude-opus-5 \
    || fail "FM_SECONDMATE_MODEL should replace a malformed pin on re-seed"
  assert_grep "; model: claude-opus-5)" "$reg" "FM_SECONDMATE_MODEL did not replace the malformed pin"
  seed "$data" validate || fail "the replaced pin should validate"
  pass "S re-seeding keeps an existing pin, refuses to drop a malformed one, FM_SECONDMATE_MODEL sets or replaces one, and a bad value is refused"
}

# Trailing whitespace or a CRLF line ending after the closing paren is not part
# of the pin field: a pinless route stays pinless and a pinned route keeps its pin.
test_trailing_whitespace_and_crlf() {
  local suffix exp n w sm launchlog out status meta
  n=0
  for suffix in ') ^default' $')\r^default' $'; model: claude-opus-5) \r^claude-opus-5'; do
    n=$((n + 1))
    exp=${suffix#*^}; suffix=${suffix%^*}
    w=$(new_world "trailing-$n")
    sm="$w/sm"
    make_seeded_home "$sm" sm
    printf -- '- sm - sm charter (home: %s; scope: sm work; projects: alpha; added 2026-01-01%s\n' \
      "$sm" "$suffix" > "$w/home/data/secondmates.md"
    launchlog="$w/launch.log"
    out=$(spawn_sm "$w" sm "$launchlog" 2>&1); status=$?
    expect_code 0 "$status" "trailing-$n: spawn should succeed"$'\n'"$out"
    meta="$w/home/state/sm.meta"
    [ "$(meta_field "$meta" model)" = "$exp" ] \
      || fail "trailing-$n: meta model '$(meta_field "$meta" model)', expected '$exp'"
    seed "$w/home/data" validate || fail "trailing-$n: route should validate"
  done
  pass "P trailing whitespace and CRLF after the route are ignored by the pin parser"
}

# ===========================================================================
# B) harness binary resolution
# ===========================================================================
test_harness_binary_resolution() {
  local w sm launchlog out status fakebin calls
  w=$(new_world binary)
  sm="$w/sm"
  make_seeded_home "$sm" sm
  add_route "$w" sm "$sm"
  printf 'claude\n' > "$w/home/config/secondmate-harness"
  launchlog="$w/launch.log"

  out=$(spawn_sm "$w" sm "$launchlog" 2>&1); status=$?
  expect_code 0 "$status" "spawn with a resolvable binary should succeed"$'\n'"$out"
  assert_contains "$(cat "$launchlog")" "=false $w/tmux-sm/fakebin/claude --dangerously-skip-permissions" \
    "launch did not name the harness by its absolute path"

  # Same spawn with claude missing from PATH: loud failure, no endpoint, no meta.
  rm -f "$w/home/state/sm.meta"
  fakebin=$(make_tmux "$w/tmux-missing")
  rm -f "$fakebin/claude"
  calls="$w/calls.log"; : > "$calls"; : > "$launchlog"
  out=$(PATH="$fakebin:$BASE_PATH" TMUX='' CLAUDECODE=1 \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$w/home" \
    FM_STATE_OVERRIDE="$w/home/state" FM_DATA_OVERRIDE="$w/home/data" \
    FM_PROJECTS_OVERRIDE="$w/home/projects" FM_CONFIG_OVERRIDE="$w/home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_LAUNCH_LOG="$launchlog" FM_TMUX_CALL_LOG="$calls" \
    "$ROOT/bin/fm-spawn.sh" sm --secondmate 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "spawn with a missing harness binary must fail"
  assert_contains "$out" "harness binary 'claude' not found as an executable on PATH" "missing binary gave no loud reason"$'\n'"$out"
  [ ! -s "$calls" ] || fail "a missing binary must fail before any endpoint is created: $(cat "$calls")"
  [ ! -s "$launchlog" ] || fail "a missing binary must never send a launch: $(cat "$launchlog")"
  assert_absent "$w/home/state/sm.meta" "a missing binary must not write meta"

  # A raw launch command is the unverified-adapter escape hatch and is sent as-is;
  # it carries no model placeholder, so meta must not claim a route pin applied.
  : > "$w/home/data/secondmates.md"
  add_route "$w" sm "$sm" claude-opus-5
  out=$(spawn_sm "$w" sm "$launchlog" "myagent --flag" 2>&1); status=$?
  expect_code 0 "$status" "raw launch should not require a resolvable harness binary"$'\n'"$out"
  assert_contains "$(cat "$launchlog")" "myagent --flag" "raw launch command was rewritten"
  [ "$(meta_field "$w/home/state/sm.meta" model)" = default ] \
    || fail "raw launch: meta model '$(meta_field "$w/home/state/sm.meta" model)', expected default despite a route pin"
  pass "B template launches use the absolute harness path; a missing binary fails loudly before any endpoint; raw launches pass through"
}

test_precedence_table
test_malformed_route_pin_fails_closed
test_prose_model_is_not_a_pin
test_bootstrap_respawn_keeps_route_pin
test_crew_and_scout_ignore_route_pin
test_registry_model_subcommand
test_write_registry_preserves_pin
test_trailing_whitespace_and_crlf
test_harness_binary_resolution
echo "# all fm-secondmate-model-pin tests passed"
