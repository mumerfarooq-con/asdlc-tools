#!/usr/bin/env bash
# Read-only git for /asdlc:review-tour. The tour pre-approves only this script, not bare `git`
# commands: a bare `git diff:*` or `git grep:*` would let a model pass any option. Here the forms are
# fixed and every ref and path is checked before git sees it. It only fetches and reads; it never
# changes the working tree, the index or any local ref (`fetch` updates the remote-tracking ref only).
#
# Usage:
#   tour-git.sh fetch <branch>               fetch origin/<branch>
#   tour-git.sh head <branch>                print the sha40 of origin/<branch>
#   tour-git.sh show <branch> <path>         the head version of <path>, numbered (git grep -n -e '' ...)
#   tour-git.sh diff <target> <branch> [<path>]
#                                            the merge-base diff origin/<target>...origin/<branch>
#   tour-git.sh changed <sha40> <branch>     names changed in <sha40>..origin/<branch> (re-review filter)
# A ref or path that starts with '-' or holds a control character is refused, as is a bad ref name.
# Exit 2 = refusal or unknown form, 1 = git failure.
set -euo pipefail

die2() { echo "tour-git: $*" >&2; exit 2; }
usage() { die2 "usage: tour-git.sh fetch|head <branch> | show <branch> <path> | diff <target> <branch> [<path>] | changed <sha40> <branch>"; }
plain() {  # <what> <text>: no leading '-', no control character, not empty
  [ -n "$2" ] || die2 "empty $1"
  case "$2" in -*) die2 "invalid $1 '$2': must not start with '-'" ;; esac
  [[ $2 =~ [[:cntrl:]] ]] && die2 "invalid $1: control character"
  return 0
}
ref() {    # <branch name>
  plain ref "$1"
  case "$1" in *'@{'*) die2 "invalid ref '$1'" ;; esac
  git check-ref-format --branch "$1" >/dev/null 2>&1 || die2 "invalid ref name '$1'"
}
path() { plain path "$1"; }
sha40() { [[ $1 =~ ^[0-9a-f]{40}$ ]] || die2 "'$1' is not a sha40"; }
# Pathspecs are literal: no `:(magic)`, no glob.
G() { git --literal-pathspecs "$@"; }

[ $# -ge 1 ] || usage
form="$1"; shift
case "$form" in
  fetch)   [ $# -eq 1 ] || usage; ref "$1"
           git fetch --quiet origin --end-of-options "$1" ;;
  head)    [ $# -eq 1 ] || usage; ref "$1"
           git rev-parse --verify --quiet --end-of-options "refs/remotes/origin/$1^{commit}" \
             || { echo "tour-git: no origin/$1 (run fetch first)" >&2; exit 1; } ;;
  show)    [ $# -eq 2 ] || usage; ref "$1"; path "$2"
           G grep -n -e '' "origin/$1" -- "$2" ;;
  diff)    { [ $# -eq 2 ] || [ $# -eq 3 ]; } || usage; ref "$1"; ref "$2"
           if [ $# -eq 3 ]; then path "$3"
             G diff --no-ext-diff --no-textconv "origin/$1...origin/$2" -- "$3"
           else G diff --no-ext-diff --no-textconv "origin/$1...origin/$2" --; fi ;;
  changed) [ $# -eq 2 ] || usage; sha40 "$1"; ref "$2"
           G diff --name-only --no-renames --no-ext-diff --no-textconv "$1..origin/$2" -- ;;
  *)       usage ;;
esac
