#!/usr/bin/env bash
# Shared config and helpers for mail mode (email intake through mail-axi).
# Mail mode is opt-in: a user puts FM_MAIL_INTAKE=<mailbox> and
# FM_MAIL_CAPTAIN=<address> into the firstmate home's .env (FM_MAIL_TENANT
# carries the tenant id mail-axi verifies). Until both are set every mail
# script is a hard no-op. FM_MAIL_ENV_FILE can point direct client calls at
# another .env-style file, but bootstrap activation still checks $FM_HOME/.env.
#
# This file is sourced, never executed. It reuses fm-x-lib.sh's generic .env and
# meta readers and defines:
#   fmm_load_config            - resolve FMM_INTAKE, FMM_CAPTAIN, FMM_TENANT
#                                (an explicit environment value wins over .env)
#   fmm_enabled                - true when FMM_INTAKE and FMM_CAPTAIN are set
#   fmm_safe_slug <value>      - true when value is a safe filename slug
#   fmm_request_dir <req>      - print data/mail-requests/<req>
#   fmm_meta_link_set <meta> <req> <epoch> - (re)write the mail_req link
#   fmm_meta_link_clear <meta> - remove the mail_req link
# Callers must have FM_HOME set before calling fmm_load_config.

FMM_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-x-lib.sh disable=SC1091
. "$FMM_LIB_DIR/fm-x-lib.sh"

fmm_load_config() {
  local env_file="${FM_MAIL_ENV_FILE:-$FM_HOME/.env}"
  if [ -n "${FM_MAIL_INTAKE+x}" ]; then FMM_INTAKE=${FM_MAIL_INTAKE-}; else FMM_INTAKE=$(fmx_env_get FM_MAIL_INTAKE "$env_file"); fi
  if [ -n "${FM_MAIL_CAPTAIN+x}" ]; then FMM_CAPTAIN=${FM_MAIL_CAPTAIN-}; else FMM_CAPTAIN=$(fmx_env_get FM_MAIL_CAPTAIN "$env_file"); fi
  # shellcheck disable=SC2034 # FMM_TENANT is read by callers (fm-mail-poll.sh) after sourcing.
  if [ -n "${FM_MAIL_TENANT+x}" ]; then FMM_TENANT=${FM_MAIL_TENANT-}; else FMM_TENANT=$(fmx_env_get FM_MAIL_TENANT "$env_file"); fi
}

fmm_enabled() {
  [ -n "${FMM_INTAKE:-}" ] && [ -n "${FMM_CAPTAIN:-}" ]
}

fmm_safe_slug() {
  case "${1:-}" in
    ''|.*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

fmm_request_dir() {
  printf '%s/mail-requests/%s\n' "${FM_DATA_OVERRIDE:-$FM_HOME/data}" "$1"
}

fmm_meta_link_set() {
  local meta=$1 req=$2 ts=$3 tmp
  [ -f "$meta" ] || return 1
  tmp=$(fmx_meta_tmp "$meta") || return 1
  if ! { grep -vE '^mail_req=|^mail_req_ts=' "$meta" || true; } > "$tmp"; then
    rm -f "$tmp"; return 1
  fi
  printf 'mail_req=%s\nmail_req_ts=%s\n' "$req" "$ts" >> "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$meta" || { rm -f "$tmp"; return 1; }
}

fmm_meta_link_clear() {
  local meta=$1 tmp
  [ -f "$meta" ] || return 0
  tmp=$(fmx_meta_tmp "$meta") || return 1
  if ! { grep -vE '^mail_req=|^mail_req_ts=' "$meta" || true; } > "$tmp"; then
    rm -f "$tmp"; return 1
  fi
  mv -f "$tmp" "$meta" || { rm -f "$tmp"; return 1; }
}
