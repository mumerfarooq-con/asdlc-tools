#!/usr/bin/env bash
# What /ovo:review reviews: writes .ovo/review/<id>/diff.patch and target.txt (through base.sh)
# and prints two lines: "Reviewing <head> against <base>, N files (M lines)" (plus any secret-
# looking untracked files left out) and "patch: <path>".
#   review-target.sh <id>                     the current branch and working tree vs origin/HEAD
#   review-target.sh <id> <branch> [<base>]   origin/<branch> vs <base> (default: origin/HEAD)
#   review-target.sh <id> <pr-url>            a Bitbucket or GitHub PR, resolved to its branches
# Branch mode fetches the two branches (GIT_TERMINAL_PROMPT=0); if that fails it warns and uses
# local refs. A Bitbucket URL needs BITBUCKET_TOKEN: one read-only GET to api.bitbucket.org, https
# only, no redirects, 30 s, the token passed on stdin (never on the command line), Bearer first and
# one Basic retry on 401 when BITBUCKET_EMAIL is set. A GitHub URL needs gh. Fork PRs are refused.
# This is the only Ovo script that uses jq (and only for a PR URL).
# Exit: 0 written; 2 bad input, no base, or a URL that can't be resolved (with the "pass the
# branch" hint); 4 more than 60 changed files (nothing written).
set -euo pipefail
export LC_ALL=C
export GIT_TERMINAL_PROMPT=0

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAX_FILES=60
HINT="pass the branch: /ovo:review <branch> [base]"
die() { echo "review-target.sh: $*" >&2; exit 2; }
warn() { echo "review-target.sh: warn: $*" >&2; }
clean() { printf '%s' "$1" | tr -cd '[:print:]' | cut -c1-200; }
okbranch() {  # <what> <name>: a branch name git accepts, not an option
  case "$2" in ''|-*) die "refusing $1 '$(clean "$2")'" ;; esac
  git check-ref-format --branch "$2" >/dev/null 2>&1 || die "refusing $1 '$(clean "$2")'"
}

[ $# -ge 1 ] && [ $# -le 3 ] || die "usage: review-target.sh <id> [<branch> [<base>] | <pr-url>]"
id="$1"; shift
[[ $id =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "refusing: the id must match [A-Za-z0-9][A-Za-z0-9._-]*"
[ "$(git rev-parse --is-inside-work-tree 2>/dev/null || true)" = true ] || die "run inside a git repo"
cd "$(git rev-parse --show-toplevel)"
dir="$("$HERE/ovo-dir.sh" "review/$id")" || exit 2

default_branch() {  # the remote's default branch name, from origin/HEAD
  local b; b="$(git symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null || true)"
  [ -n "$b" ] || die "no default branch: pass a base"
  printf '%s' "${b#origin/}"
}

# One read-only GET to the Bitbucket API. Prints the HTTP code; the body goes to $1.
bb_get() {  # <outfile> <url> <auth: bearer|basic>
  local cfg
  if [ "$3" = basic ]; then cfg="user = \"$BITBUCKET_EMAIL:$BITBUCKET_TOKEN\""
  else cfg="header = \"Authorization: Bearer $BITBUCKET_TOKEN\""; fi
  printf '%s\n' "$cfg" | (unset BITBUCKET_TOKEN BITBUCKET_EMAIL
    exec curl -sS --proto =https --max-redirs 0 --max-time 30 -H "Accept: application/json" \
      -o "$1" -w '%{http_code}' --config - -- "$2")
}

resolve_bitbucket() {  # <url>: sets branch, base
  local re='^https://bitbucket\.org/([A-Za-z0-9._-]+)/([A-Za-z0-9._-]+)/pull-requests/([0-9]{1,9})(/[a-z]+)?/?$'
  [[ $1 =~ $re ]] || die "not a Bitbucket PR URL (want https://bitbucket.org/<workspace>/<repo>/pull-requests/<n>)"
  local ws="${BASH_REMATCH[1]}" repo="${BASH_REMATCH[2]}" n="${BASH_REMATCH[3]}" v
  for v in "$ws" "$repo"; do
    case "$v" in .|..|-*) die "refusing the workspace or repo '$(clean "$v")'" ;; esac
  done
  [ -n "${BITBUCKET_TOKEN:-}" ] || die "a Bitbucket PR URL needs BITBUCKET_TOKEN; $HINT"
  case "$BITBUCKET_TOKEN${BITBUCKET_EMAIL:-}" in *[[:space:][:cntrl:]\"\\]*) die "BITBUCKET_TOKEN or BITBUCKET_EMAIL has a character Ovo won't send; $HINT" ;; esac
  command -v curl >/dev/null && command -v jq >/dev/null || die "a Bitbucket PR URL needs curl and jq; $HINT"
  local api="https://api.bitbucket.org/2.0/repositories/$ws/$repo/pullrequests/$n"
  local body="$dir/.pr.json" code
  code="$(bb_get "$body" "$api" bearer)" || { rm -f "$body"; die "could not reach api.bitbucket.org; $HINT"; }
  if [ "$code" = 401 ] && [ -n "${BITBUCKET_EMAIL:-}" ]; then
    code="$(bb_get "$body" "$api" basic)" || { rm -f "$body"; die "could not reach api.bitbucket.org; $HINT"; }
  fi
  if [ "$code" != 200 ]; then rm -f "$body"; die "Bitbucket answered HTTP $(clean "$code") for that PR; $HINT"; fi
  local fields
  # One field per line: an empty field stays empty (a tab separator would collapse it).
  fields="$(jq -r '.source.branch.name, .destination.branch.name,
      .source.repository.full_name, .destination.repository.full_name | . // ""' "$body" 2>/dev/null)" \
    || { rm -f "$body"; die "could not read Bitbucket's answer; $HINT"; }
  rm -f "$body"
  { IFS= read -r branch; IFS= read -r base; IFS= read -r src; IFS= read -r dst; } <<EOF || true
$fields
EOF
  [ -n "$src" ] && [ "$src" = "$dst" ] || die "this PR comes from a fork; $HINT"
}

resolve_github() {  # <url>: sets branch, base
  local re='^https://github\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+/pull/[0-9]{1,9}(/[a-z]+)?/?$'
  [[ $1 =~ $re ]] || die "not a GitHub PR URL (want https://github.com/<owner>/<repo>/pull/<n>)"
  command -v gh >/dev/null || die "a GitHub PR URL needs the gh CLI; $HINT"
  command -v jq >/dev/null || die "a GitHub PR URL needs jq; $HINT"
  local out
  out="$(GH_PROMPT_DISABLED=1 gh pr view "$1" --json headRefName,baseRefName,isCrossRepository 2>/dev/null)" \
    || die "gh could not read that PR; $HINT"
  out="$(printf '%s' "$out" | jq -r '(.headRefName // ""), (.baseRefName // ""), (.isCrossRepository | tostring)' 2>/dev/null)" \
    || die "could not read gh's answer; $HINT"
  local cross
  { IFS= read -r branch; IFS= read -r base; IFS= read -r cross; } <<EOF || true
$out
EOF
  [ "$cross" = false ] || die "this PR comes from a fork; $HINT"
}

args=(--write "review/$id" --max-files "$MAX_FILES")
branch=""; base=""
case "${1:-}" in
  "") ;;
  http://*|https://*)
    [ $# -eq 1 ] || die "a PR URL takes no base"
    case "$1" in
      https://bitbucket.org/*) resolve_bitbucket "$1" ;;
      https://github.com/*) resolve_github "$1" ;;
      *) die "not a Bitbucket or GitHub PR URL (https only); $HINT" ;;
    esac
    [ -n "$branch" ] && [ -n "$base" ] || die "could not read the PR's branches; $HINT" ;;
  *) branch="$1"; base="${2:-}" ;;
esac

if [ -n "$branch" ]; then
  okbranch branch "$branch"
  [ -n "$base" ] || base="$(default_branch)"
  okbranch base "$base"
  git fetch -q origin "$branch" "$base" 2>/dev/null || warn "could not fetch $branch and $base from origin; using local refs"
  head_ref="origin/$branch"
  git rev-parse -q --verify "$head_ref^{commit}" >/dev/null || head_ref="$branch"
  base_ref="origin/$base"
  git rev-parse -q --verify "$base_ref^{commit}" >/dev/null || base_ref="$base"
  args+=(--head "$head_ref" "$base_ref")
fi

out="$("$HERE/base.sh" "${args[@]}")" || exit $?
val() { printf '%s\n' "$out" | sed -n "s/^$1: //p"; }
line="Reviewing $(val head) against $(val base), $(val files) files ($(val lines) lines)"
[ "$(val skipped)" = none ] || line="$line; left out secret-looking untracked files: $(val skipped)"
echo "$line"
echo "patch: $(val patch)"
