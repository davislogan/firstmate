#!/usr/bin/env bash
# fm-pr-lib.sh - single owner of the "full GitHub PR URL -> owner, repo,
# number" parse used everywhere firstmate handles a task's PR reference
# (AGENTS.md requires full https:// PR URLs, never bare numbers).
# Sourced by fm-pr-merge.sh, fm-pr-sanitize.sh, and fm-pr-conflict-sweep.sh.
#
# fm_pr_parse_url <url>: on success sets PR_OWNER, PR_REPO, PR_NUMBER and
# returns 0; on a malformed URL prints an error to stderr and returns 1.

# The results are consumed by sourcing scripts, so they read as "unused" here.
# shellcheck disable=SC2034
fm_pr_parse_url() {
  local url=$1
  if [[ "$url" =~ ^https://github\.com/([A-Za-z0-9][A-Za-z0-9-]{0,38})/([A-Za-z0-9._-]+)/pull/([0-9]+)/?$ ]]; then
    PR_OWNER="${BASH_REMATCH[1]}"
    PR_REPO="${BASH_REMATCH[2]}"
    PR_NUMBER="${BASH_REMATCH[3]}"
    if [[ "$PR_OWNER" != *- ]]; then
      return 0
    fi
  fi
  echo "error: PR URL must match https://github.com/<owner>/<repo>/pull/<number> (got: $url)" >&2
  return 1
}
