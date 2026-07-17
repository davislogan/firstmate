#!/usr/bin/env bash
# fm-pr-sanitize.sh - belt-and-suspenders guarantee that no unicode dash
# survives in a PR title or body, regardless of what composed them (the
# validation pipeline's PR generator does not inherit the captain's
# no-em-dash rule, so em dashes leak into PR descriptions).
#
# Fetches the PR's title and body byte-exact via `gh pr view --json`,
# transliterates every unicode dash to a plain ASCII hyphen, and edits the PR
# only when something changed, so it is idempotent and safe to re-run at
# every PR-ready step. Prints one line when it edited the PR; prints nothing
# when already clean.
#
# Covered dashes (matched as UTF-8 byte sequences, locale-independent):
# U+2010 hyphen, U+2011 non-breaking hyphen, U+2012 figure dash, U+2013 en
# dash, U+2014 em dash, U+2015 horizontal bar, U+2212 minus sign, U+FE58
# small em dash, U+FE63 small hyphen-minus, U+FF0D fullwidth hyphen-minus.
#
# The write goes through `gh-axi pr edit <n> --repo <owner>/<repo>`, the same
# global --repo scoping fm-pr-merge.sh uses (confirmed respected read-only via
# `gh-axi pr view <n> --repo <other-repo>` returning that repo's view,
# 2026-07-16).
# Usage: fm-pr-sanitize.sh <pr-url>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-pr-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-pr-lib.sh"

URL=${1:?usage: fm-pr-sanitize.sh <pr-url>}
fm_pr_parse_url "$URL" || exit 1

TITLE=$(gh pr view "$URL" --json title -q .title) \
  || { echo "fm-pr-sanitize: could not read PR title for $URL" >&2; exit 1; }
BODY=$(gh pr view "$URL" --json body -q .body) \
  || { echo "fm-pr-sanitize: could not read PR body for $URL" >&2; exit 1; }

# Each entry is one unicode dash as its UTF-8 byte sequence, so the pure-bash
# replacement below works identically under any locale and any bash >= 3.2.
DASHES=(
  $'\xe2\x80\x90'  # U+2010 hyphen
  $'\xe2\x80\x91'  # U+2011 non-breaking hyphen
  $'\xe2\x80\x92'  # U+2012 figure dash
  $'\xe2\x80\x93'  # U+2013 en dash
  $'\xe2\x80\x94'  # U+2014 em dash
  $'\xe2\x80\x95'  # U+2015 horizontal bar
  $'\xe2\x88\x92'  # U+2212 minus sign
  $'\xef\xb9\x98'  # U+FE58 small em dash
  $'\xef\xb9\xa3'  # U+FE63 small hyphen-minus
  $'\xef\xbc\x8d'  # U+FF0D fullwidth hyphen-minus
)

sanitize() {
  local s=$1 ch
  for ch in "${DASHES[@]}"; do
    s=${s//"$ch"/-}
  done
  printf '%s' "$s"
}

NEW_TITLE=$(sanitize "$TITLE")
NEW_BODY=$(sanitize "$BODY")

if [ "$NEW_TITLE" = "$TITLE" ] && [ "$NEW_BODY" = "$BODY" ]; then
  exit 0
fi

TMP=$(mktemp "${TMPDIR:-/tmp}/fm-pr-sanitize.XXXXXX")
trap 'rm -f "$TMP"' EXIT
printf '%s\n' "$NEW_BODY" > "$TMP"
gh-axi pr edit "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" --title "$NEW_TITLE" --body-file "$TMP" >/dev/null \
  || { echo "fm-pr-sanitize: gh-axi pr edit failed for $URL" >&2; exit 1; }
echo "sanitized unicode dashes in PR #$PR_NUMBER title/body"
