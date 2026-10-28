# shellcheck shell=bash
# Shared per-route model pin grammar for data/secondmates.md routes.
# Usage: . bin/fm-secondmate-route-lib.sh
#
# The contract owner is the secondmate-provisioning skill ("Per-route model
# pin"); this file is the one implementation of its grammar, sourced by
# bin/fm-spawn.sh (reads the pin on every --secondmate spawn) and
# bin/fm-home-seed.sh (writes and validates it), so the two never drift.
#
# Only the structured tail after the LAST "; added <date>" is the pin field, so a
# "model:" in the charter summary or scope prose is never read as a pin. After
# trailing whitespace and CR are stripped, that tail must be exactly ")" (no pin)
# or "; model: <token>)" (a pin); anything else is malformed.

# fm_route_pin_token_ok <token>: a pin token is one shell-safe word that does not
# start with "-". "default" passes here; callers decide what it means.
fm_route_pin_token_ok() {
  case "$1" in
    ''|-*|*[!A-Za-z0-9._:/@+=\[\]-]*) return 1 ;;
  esac
}

# fm_route_valid_model_pin <token>: a token that may be written as a pin.
# "default" is refused because it is not a pin.
fm_route_valid_model_pin() {
  [ "$1" != default ] && fm_route_pin_token_ok "$1"
}

# fm_route_pin_state <route-line>: prints "none", "pin <token>", or "malformed".
fm_route_pin_state() {
  local tail tok
  tail=$(printf '%s\n' "$1" | sed -n 's/^.*; added [^;)[:space:]]*//p')
  tail=${tail%"${tail##*[![:space:]]}"}
  case "$tail" in
    ''|')') echo none ;;
    '; model: '*')')
      tok=${tail#; model: }
      tok=${tok%)}
      if fm_route_pin_token_ok "$tok"; then
        printf 'pin %s\n' "$tok"
      else
        echo malformed
      fi
      ;;
    *) echo malformed ;;
  esac
}
