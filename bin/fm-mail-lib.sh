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
#   fmm_load_config            - resolve FMM_INTAKE, FMM_CAPTAIN, FMM_TENANT,
#                                FMM_SEND, FMM_AXI_SETTING, FMM_HTML,
#                                FMM_POLL_TIMEOUT, FMM_ERROR_THRESHOLD (an
#                                explicit environment value wins over .env)
#   fmm_resolve_axi            - resolve the mail tool into FMM_AXI and export
#                                FM_HOME; on failure set FMM_AXI_ERROR and return 1
#   fmm_enabled                - true when FMM_INTAKE and FMM_CAPTAIN are set
#   fmm_send_enabled           - true when FM_MAIL_SEND=1 (real sends opted in)
#   fmm_safe_slug <value>      - true when value is a safe filename slug
#   fmm_request_dir <req>      - print data/mail-requests/<req>
#   fmm_meta_link_set <meta> <req> <epoch> - (re)write the mail_req link
#   fmm_meta_link_clear <meta> - remove the mail_req link
# Callers must have FM_HOME set before calling fmm_load_config.
#
# Mail tool resolution (the one owner; every mail-axi call goes through FMM_AXI):
#   FM_MAIL_AXI set     -> must be an absolute path to an executable file; if it
#                          is not, fail closed and never fall back to PATH.
#   FM_MAIL_AXI unset   -> exactly one distinct `mail-axi` on PATH is used; none,
#                          or several different ones, fail closed. Single-tool
#                          installs keep working unchanged, while a machine where
#                          two tools answer to `mail-axi` must name one, because
#                          PATH order differs between login shells, tmux panes,
#                          and harness shell snapshots.
# FM_HOME is exported so a tool that routes on it (a per-home shim) sees the
# same home as the calling script, including for hand-run helpers.

FMM_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-x-lib.sh disable=SC1091
. "$FMM_LIB_DIR/fm-x-lib.sh"

fmm_load_config() {
  local env_file="${FM_MAIL_ENV_FILE:-$FM_HOME/.env}"
  if [ -n "${FM_MAIL_INTAKE+x}" ]; then FMM_INTAKE=${FM_MAIL_INTAKE-}; else FMM_INTAKE=$(fmx_env_get FM_MAIL_INTAKE "$env_file"); fi
  if [ -n "${FM_MAIL_CAPTAIN+x}" ]; then FMM_CAPTAIN=${FM_MAIL_CAPTAIN-}; else FMM_CAPTAIN=$(fmx_env_get FM_MAIL_CAPTAIN "$env_file"); fi
  # shellcheck disable=SC2034 # FMM_TENANT is read by callers (fm-mail-poll.sh) after sourcing.
  if [ -n "${FM_MAIL_TENANT+x}" ]; then FMM_TENANT=${FM_MAIL_TENANT-}; else FMM_TENANT=$(fmx_env_get FM_MAIL_TENANT "$env_file"); fi
  if [ -n "${FM_MAIL_SEND+x}" ]; then FMM_SEND=${FM_MAIL_SEND-}; else FMM_SEND=$(fmx_env_get FM_MAIL_SEND "$env_file"); fi
  if [ -n "${FM_MAIL_AXI+x}" ]; then FMM_AXI_SETTING=${FM_MAIL_AXI-}; else FMM_AXI_SETTING=$(fmx_env_get FM_MAIL_AXI "$env_file"); fi
  # shellcheck disable=SC2034 # FMM_HTML is read by fm-mail-reply.sh.
  if [ -n "${FM_MAIL_HTML+x}" ]; then FMM_HTML=${FM_MAIL_HTML-}; else FMM_HTML=$(fmx_env_get FM_MAIL_HTML "$env_file"); fi
  # shellcheck disable=SC2034 # FMM_POLL_TIMEOUT and FMM_ERROR_THRESHOLD are read by fm-mail-poll.sh.
  if [ -n "${FM_MAIL_POLL_TIMEOUT+x}" ]; then FMM_POLL_TIMEOUT=${FM_MAIL_POLL_TIMEOUT-}; else FMM_POLL_TIMEOUT=$(fmx_env_get FM_MAIL_POLL_TIMEOUT "$env_file"); fi
  # shellcheck disable=SC2034
  if [ -n "${FM_MAIL_ERROR_THRESHOLD+x}" ]; then FMM_ERROR_THRESHOLD=${FM_MAIL_ERROR_THRESHOLD-}; else FMM_ERROR_THRESHOLD=$(fmx_env_get FM_MAIL_ERROR_THRESHOLD "$env_file"); fi
}

# True when replies default to HTML: on unless FM_MAIL_HTML is 0.
fmm_html_default() {
  [ "${FMM_HTML:-}" != 0 ]
}

# shellcheck disable=SC2034 # FMM_AXI and FMM_AXI_ERROR are read by callers.
fmm_resolve_axi() {
  local p real found='' found_all='' distinct=0 seen=''
  FMM_AXI=
  FMM_AXI_ERROR=
  export FM_HOME
  if [ -n "${FMM_AXI_SETTING:-}" ]; then
    case "$FMM_AXI_SETTING" in
      /*) ;;
      *) FMM_AXI_ERROR="FM_MAIL_AXI must be an absolute path: $FMM_AXI_SETTING"; return 1 ;;
    esac
    if [ ! -f "$FMM_AXI_SETTING" ] || [ ! -x "$FMM_AXI_SETTING" ]; then
      FMM_AXI_ERROR="FM_MAIL_AXI=$FMM_AXI_SETTING is missing or not executable"
      return 1
    fi
    FMM_AXI=$FMM_AXI_SETTING
    return 0
  fi
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    real=$(readlink -f "$p" 2>/dev/null) || real=$p
    [ -n "$real" ] || real=$p
    case "$seen" in *"|$real|"*) continue ;; esac
    seen="$seen|$real|"
    distinct=$((distinct + 1))
    [ -n "$found" ] || found=$p
    found_all="${found_all:+$found_all, }$p"
  done < <(type -ap mail-axi 2>/dev/null)
  if [ "$distinct" -eq 0 ]; then
    FMM_AXI_ERROR="mail-axi not found on PATH and FM_MAIL_AXI unset"
    return 1
  fi
  if [ "$distinct" -gt 1 ]; then
    FMM_AXI_ERROR="FM_MAIL_AXI unset and PATH has $distinct different mail-axi; set FM_MAIL_AXI (found: $found_all)"
    return 1
  fi
  FMM_AXI=$found
}

fmm_send_enabled() {
  [ "${FMM_SEND:-}" = 1 ]
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
