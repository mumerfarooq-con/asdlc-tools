#!/usr/bin/env bash
# Where Ovo writes: <git top>/.ovo/<sub>, every directory created with mode 700. The first use
# also writes .ovo/.gitignore containing "*", so the directory ignores itself: nobody edits a
# .gitignore, and `git status` stays clean.
#   ovo-dir.sh <sub>                   e.g. impact/<id>; prints the absolute path
#   ovo-dir.sh <kind> --new [<name>]   a fresh <kind>/<slug>-<UTC yyyymmddHHMM>, where <slug> comes
#                                      from <name> (default: the current branch); -2, -3... if taken
# Refuses a symlinked .ovo, .ovo/.gitignore or any part of <sub>, and anything outside a git
# work tree. Exit: 0 printed; 2 refused or bad input.
set -euo pipefail
export LC_ALL=C

die() { echo "ovo-dir.sh: $*" >&2; exit 2; }
part='[A-Za-z0-9][A-Za-z0-9._-]*'

[ "$(git rev-parse --is-inside-work-tree 2>/dev/null || true)" = true ] || die "run inside a git repo"
top="$(git rev-parse --show-toplevel 2>/dev/null)" || die "run inside a git repo"
[ -n "$top" ] || die "run inside a git repo"

sub="${1:-}"
[ -n "$sub" ] || die "usage: ovo-dir.sh <sub> | <kind> --new [<name>]"
if [ "${2:-}" = --new ]; then
  [ $# -le 3 ] || die "usage: ovo-dir.sh <kind> --new [<name>]"
  [[ $sub =~ ^$part$ ]] || die "refusing kind '$sub': want letters, digits, '.', '_' or '-'"
  name="${3:-}"
  [ -n "$name" ] || name="$(git symbolic-ref -q --short HEAD 2>/dev/null || echo detached)"
  slug="$(printf '%s' "$name" | tr -c 'A-Za-z0-9._-' '-' | tr -s '-' | cut -c1-40)"
  while [ -n "$slug" ] && case "$slug" in [-._]*|*[-._]) true ;; *) false ;; esac; do
    slug="${slug#[-._]}"; slug="${slug%[-._]}"
  done
  [ -n "$slug" ] || slug=head
  id="$slug-$(date -u +%Y%m%d%H%M)"
  cand="$id"; k=1
  while [ -e "$top/.ovo/$sub/$cand" ] || [ -L "$top/.ovo/$sub/$cand" ]; do
    k=$((k + 1)); [ "$k" -le 99 ] || die "too many runs named $id"
    cand="$id-$k"
  done
  sub="$sub/$cand"
else
  [ $# -eq 1 ] || die "usage: ovo-dir.sh <sub>"
fi
[ "${#sub}" -le 200 ] || die "refusing: the path is too long"
[[ $sub =~ ^$part(/$part)*$ ]] || die "refusing '$sub': want parts of letters, digits, '.', '_' or '-', not starting with '.' or '-'"

umask 077
mkpart() {  # <path>: refuse a link or a non-directory, else create it
  if [ -L "$1" ]; then die "refusing: $1 is a symbolic link"; fi
  if [ -e "$1" ] && [ ! -d "$1" ]; then die "refusing: $1 is not a directory"; fi
  [ -d "$1" ] || mkdir -m 700 "$1"
}
base="$top/.ovo"
mkpart "$base"
gi="$base/.gitignore"
if [ -L "$gi" ]; then die "refusing: $gi is a symbolic link"; fi
[ -e "$gi" ] || printf '*\n' > "$gi"

p="$base"; rest="$sub"
while [ -n "$rest" ]; do
  c="${rest%%/*}"
  if [ "$c" = "$rest" ]; then rest=""; else rest="${rest#*/}"; fi
  p="$p/$c"
  mkpart "$p"
done
printf '%s\n' "$p"
