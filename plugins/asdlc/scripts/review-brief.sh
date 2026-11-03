#!/usr/bin/env bash
# Local helper for the reviewer brief (plans/<KEY>/review-brief.md). No network; it writes only under
# plans/<KEY>/. It never prints diff text or brief text: the brief carries ticket text, and the
# caller (jira-run) must not see it.
#
# Usage:
#   review-brief.sh diff <KEY> <base> <head> [--since <sha>]
#       writes plans/<KEY>/review.diff: a header line, `git diff --stat`, then the merge-base diff of
#       <base>..<head> (or <since>..<head> for a re-review). Capped at 200 KB: a bigger diff is cut and
#       ends with a marker line. Prints `review.diff: <path> files=<n> lines=<n> head=<short sha>
#       [since=<short sha>] [truncated=yes]`.
#   review-brief.sh check <KEY> [--rereview]
#       validates plans/<KEY>/review-brief.md. Prints `BRIEF ok <lines> lines <tests> tests`, or
#       `BRIEF invalid: <problem>` and exit 2. Checks: first line `[asdlc] Reviewer brief — <KEY> at <short sha>`,
#       the required headings once each and in order, at most 150 lines and 12 KB, at most 5 rows under
#       "Human must read". "tests" counts the lines containing "asserts" under "## Tests first".
#       --rereview also requires `## Changed since your review at <short sha>` (last).
#       A brief with a secret-like token shape (PEM private key header, AKIA, ghp_, github_pat_, xox[abprs]-, ATATT)
#       is refused: `BRIEF invalid: <n> secret-like string(s)`, never the text.
# Exit 2 = refusal or invalid brief, 1 = git failure.
set -euo pipefail
. "$(dirname "$0")/../jira/scripts/lib.sh"

DIFF_CAP=204800      # bytes of review.diff before it is cut
MAX_LINES=150
MAX_BYTES=12288
MAX_HUNK_ROWS=5

die2() { echo "review-brief: $*" >&2; exit 2; }
# asdlc_need_key and asdlc_need_dir (review-lib.sh) report through die2.
bad_ref() { case "$1" in -*) die2 "invalid ref '$1': must not start with '-'" ;; esac; }
resolve() {  # <ref> -> full sha, or exit 2
  local s
  bad_ref "$1"
  s="$(git rev-parse --verify --quiet --end-of-options "$1^{commit}" 2>/dev/null)" || die2 "cannot resolve '$1' to a commit"
  printf '%s' "$s"
}

cmd_diff() {
  local KEY="${1:-}" base="${2:-}" head="${3:-}" since=""
  [ $# -ge 3 ] || die2 "usage: review-brief.sh diff <KEY> <base> <head> [--since <sha>]"
  shift 3
  if [ $# -gt 0 ]; then
    [ $# -eq 2 ] && [ "$1" = --since ] || die2 "usage: review-brief.sh diff <KEY> <base> <head> [--since <sha>]"
    since="$2"
  fi
  asdlc_need_key "$KEY"
  local bsha hsha ssha="" from dir out tmp mb
  bsha="$(resolve "$base")"; hsha="$(resolve "$head")"
  [ -z "$since" ] || ssha="$(resolve "$since")"
  if [ -n "$ssha" ]; then from="$ssha"
  else
    mb="$(git merge-base "$bsha" "$hsha" 2>/dev/null)" || die2 "no merge base between '$base' and '$head'"
    from="$mb"
  fi
  dir="$(asdlc_need_dir "$KEY")"
  mkdir -p "$dir"
  out="$dir/review.diff"
  [ ! -L "$out" ] || die2 "$out is a symlink"
  [ ! -e "$out" ] || [ -f "$out" ] || die2 "$out is not a regular file"
  tmp="$(mktemp "$dir/.review.diff.XXXXXX")"
  trap 'rm -f "$tmp"' EXIT
  {
    printf '# asdlc review.diff: head %s' "$(git rev-parse --short "$hsha")"
    if [ -n "$ssha" ]; then printf ' since %s\n' "$(git rev-parse --short "$ssha")"
    else printf ' base %s\n' "$(git rev-parse --short "$bsha")"; fi
    git diff --no-color --no-ext-diff --no-textconv --stat "$from" "$hsha" --
    echo
    git diff --no-color --no-ext-diff --no-textconv "$from" "$hsha" --
  } > "$tmp" || { echo "review-brief: git diff failed" >&2; exit 1; }
  local files lines trunc=""
  files="$(git diff --no-ext-diff --no-textconv --name-only "$from" "$hsha" -- | wc -l | tr -d ' ')"
  lines="$(git diff --no-ext-diff --no-textconv --numstat "$from" "$hsha" -- | awk '{ if ($1 ~ /^[0-9]+$/) s += $1; if ($2 ~ /^[0-9]+$/) s += $2 } END { print s + 0 }')"
  if [ "$(wc -c < "$tmp" | tr -d ' ')" -gt "$DIFF_CAP" ]; then
    head -c "$DIFF_CAP" "$tmp" > "$tmp.cut"
    mv "$tmp.cut" "$tmp"
    printf '\n[asdlc] diff truncated at %s bytes: read the changed files for the rest\n' "$DIFF_CAP" >> "$tmp"
    trunc=" truncated=yes"
  fi
  mv "$tmp" "$out"; trap - EXIT
  printf 'review.diff: %s files=%s lines=%s head=%s%s%s\n' "$out" "$files" "$lines" \
    "$(git rev-parse --short "$hsha")" "${ssha:+ since=$(git rev-parse --short "$ssha")}" "$trunc"
}

cmd_check() {
  local KEY="${1:-}" rereview=0
  [ $# -ge 1 ] || die2 "usage: review-brief.sh check <KEY> [--rereview]"
  shift
  if [ $# -gt 0 ]; then [ $# -eq 1 ] && [ "$1" = --rereview ] || die2 "usage: review-brief.sh check <KEY> [--rereview]"; rereview=1; fi
  asdlc_need_key "$KEY"
  local dir f
  dir="$(asdlc_need_dir "$KEY")"
  f="$dir/review-brief.md"
  invalid() { echo "BRIEF invalid: $*"; exit 2; }
  [ ! -L "$f" ] || invalid "review-brief.md is a symlink"
  [ -f "$f" ] || invalid "review-brief.md not found"
  local bytes lines first
  bytes="$(wc -c < "$f" | tr -d ' ')"
  lines="$(tr -d '\r' < "$f" | awk 'END { print NR }')"
  [ "$bytes" -le "$MAX_BYTES" ] || invalid "over $MAX_BYTES bytes ($bytes)"
  [ "$lines" -le "$MAX_LINES" ] || invalid "over $MAX_LINES lines ($lines)"
  first="$(head -n1 "$f" | tr -d '\r')"
  [[ $first =~ ^\[asdlc\]\ Reviewer\ brief\ —\ ([A-Z][A-Z0-9_]*-[0-9]+)\ at\ ([0-9a-f]{7,40})$ ]] \
    || invalid "first line is not '[asdlc] Reviewer brief — <KEY> at <short sha>'"
  [ "${BASH_REMATCH[1]}" = "$KEY" ] || invalid "first line names another ticket"
  # Secret-like token shapes (N-5): the brief is posted to a PR. Counts only, never the text.
  # No generic hex run: a brief cites commit shas.
  local nsec
  nsec="$(tr -d '\r' < "$f" | grep -Ec -e '-----BEGIN [A-Z ]*PRIVATE KEY-----' -e 'AKIA[0-9A-Z]{16}' \
    -e 'ghp_[A-Za-z0-9]{36}' -e 'github_pat_[A-Za-z0-9_]{22,}' -e 'xox[abprs]-[A-Za-z0-9-]{10,}' \
    -e 'ATATT[A-Za-z0-9_=-]{20,}' || true)"
  [ "${nsec:-0}" -eq 0 ] || invalid "$nsec secret-like string(s)"
  local want="Intent|Tests first|Human must read|Deviations from the plan|Out of scope|Reading order|Check on dev"
  [ "$rereview" -eq 0 ] || want="$want|Changed since your review at"
  # One awk pass: required headings once each, in order; rows under Human must read; asserts under Tests first.
  local res
  res="$(tr -d '\r' < "$f" | awk -v want="$want" -v maxrows="$MAX_HUNK_ROWS" '
    BEGIN { n = split(want, w, "|"); next_i = 1 }
    /^## / {
      h = substr($0, 4); sub(/[ \t]+$/, "", h); sec = h
      for (i = 1; i <= n; i++) {
        full = w[i]
        if (i == n && full == "Changed since your review at") ok = (h ~ /^Changed since your review at [0-9a-f]+$/)
        else ok = (h == full)
        if (ok) {
          if (seen[i]) { if (err == "") err = "duplicate heading: " full }
          if (i < next_i) { if (err == "") err = "heading out of order: " full }
          seen[i] = 1; next_i = i + 1
        }
      }
      next
    }
    sec == "Tests first" && /asserts/ { tests++ }
    sec == "Human must read" && /^\|[ \t]*[0-9]+[ \t]*\|/ { rows++ }
    END {
      if (err != "") { print err; exit }
      if (rows > maxrows) { print "more than " maxrows " rows under Human must read"; exit }
      for (i = 1; i <= n; i++) if (!seen[i]) { print "missing heading: ## " w[i]; exit }
      print "ok " tests + 0
    }')"
  case "$res" in
    ok\ *) printf 'BRIEF ok %s lines %s tests\n' "$lines" "${res#ok }" ;;
    *) invalid "$res" ;;
  esac
}

case "${1:-}" in
  diff)  shift; cmd_diff "$@" ;;
  check) shift; cmd_check "$@" ;;
  *) die2 "usage: review-brief.sh diff <KEY> <base> <head> [--since <sha>] | check <KEY> [--rereview]" ;;
esac
