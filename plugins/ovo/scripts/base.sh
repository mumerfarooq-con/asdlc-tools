#!/usr/bin/env bash
# The base a change is measured against, and the change itself.
#   base.sh [--head <ref>] [--write <sub>] [--max-files <n>] [<base>]
# <base> defaults to the remote's default branch (origin/HEAD). Without --head the change is the
# working tree: the merge-base of <base> and HEAD, up to every staged, unstaged and untracked
# (not ignored) file. With --head it is the merge-base up to <ref>, and nothing local.
# Untracked files whose path has a secret-looking part (the impact core's globs) are left out and
# listed as "skipped"; tracked files are always in the diff, secret-looking or not. An untracked
# nested repository is not diffed. Scratch files stay in .ovo/tmp.
# Prints "key: value" lines: base, head, merge-base, files, lines, untracked, skipped.
# --write <sub> also writes .ovo/<sub>/diff.patch and .ovo/<sub>/target.txt: the same lines, then
# "## files" (added deleted path per file) and "## functions" (path: the hunk's function context,
# from git's hunk headers), and adds "patch: <path>" to the output. --max-files <n>: more changed
# files than that exits 4 and writes nothing.
# Exit: 0 printed; 2 no base, an unknown ref, no merge-base or bad input; 4 too many files.
set -euo pipefail
export LC_ALL=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
die() { echo "base.sh: $*" >&2; exit 2; }
usage() { die "usage: base.sh [--head <ref>] [--write <sub>] [--max-files <n>] [<base>]"; }
okref() {  # <what> <ref>: a ref or sha, never an option or a control character
  case "$2" in ''|-*|*[[:cntrl:]]*|*[[:space:]]*) die "refusing $1 '$(printf '%s' "$2" | tr -cd '[:print:]')'" ;; esac
}

head=""; sub=""; max=""; base=""
while [ $# -gt 0 ]; do
  case "$1" in
    --head) [ $# -ge 2 ] || usage; okref head "$2"; head="$2"; shift 2 ;;
    --write) [ $# -ge 2 ] || usage; sub="$2"; shift 2 ;;
    --max-files) [ $# -ge 2 ] && [[ $2 =~ ^[0-9]{1,5}$ ]] || usage; max="$2"; shift 2 ;;
    -*) usage ;;
    *) [ -z "$base" ] || usage; okref base "$1"; base="$1"; shift ;;
  esac
done

[ "$(git rev-parse --is-inside-work-tree 2>/dev/null || true)" = true ] || die "run inside a git repo"
top="$(git rev-parse --show-toplevel)"
cd "$top"
if [ -z "$base" ]; then
  base="$(git symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null || true)"
  [ -n "$base" ] || die "no default branch: pass a base"
fi
git rev-parse -q --verify "$base^{commit}" >/dev/null || die "unknown base '$base'"
if [ -n "$head" ]; then
  git rev-parse -q --verify "$head^{commit}" >/dev/null || die "unknown head '$head'"
  tip="$head"; head_label="$head"
else
  git rev-parse -q --verify "HEAD^{commit}" >/dev/null || die "no commits yet"
  tip=HEAD
  head_label="$(git symbolic-ref -q --short HEAD || git rev-parse --short HEAD) (working tree)"
fi
mb="$(git merge-base "$base" "$tip" 2>/dev/null)" || die "no merge-base between '$base' and '$tip'"

# Scratch stays inside .ovo, like everything Ovo writes.
work="$(mktemp -d "$("$HERE/ovo-dir.sh" tmp)/base.XXXXXX")" || exit 2
trap 'rm -rf "$work"' EXIT
D=(git -c core.quotepath=off diff --no-color --no-ext-diff --no-textconv)

# Tracked changes.
if [ -n "$head" ]; then
  "${D[@]}" "$mb" "$head" > "$work/patch"
  "${D[@]}" --numstat "$mb" "$head" > "$work/numstat"
else
  "${D[@]}" "$mb" > "$work/patch"
  "${D[@]}" --numstat "$mb" > "$work/numstat"
fi

# Untracked files (working tree only), as new-file diffs; secret-looking paths are skipped.
GLOBS=()
while IFS= read -r g; do [ -n "$g" ] && GLOBS+=("$g"); done < <("$HERE/impact-core.sh" --secret-globs)
[ "${#GLOBS[@]}" -gt 0 ] || die "the impact core printed no secret globs (broken install?)"
secret() {  # <path>: true when any part of it matches a glob
  local rest="$1" c g
  while [ -n "$rest" ]; do
    c="${rest%%/*}"; if [ "$c" = "$rest" ]; then rest=""; else rest="${rest#*/}"; fi
    for g in "${GLOBS[@]}"; do
      # shellcheck disable=SC2254
      case "$c" in $g) return 0 ;; esac
    done
  done
  return 1
}
untracked=0; skipped=""; nskipped=0
if [ -z "$head" ]; then
  while IFS= read -r -d '' f; do
    [ ! -d "$f" ] || continue   # an untracked nested repo: not diffed
    if secret "$f"; then
      nskipped=$((nskipped + 1))
      [ "$nskipped" -gt 10 ] || skipped="$skipped${skipped:+, }$(printf '%s' "$f" | tr -cd '[:print:]')"
      continue
    fi
    untracked=$((untracked + 1))
    "${D[@]}" --no-index -- /dev/null "$f" >> "$work/patch" || [ $? -eq 1 ] || die "cannot diff untracked $f"
    "${D[@]}" --no-index --numstat -- /dev/null "$f" >> "$work/numstat" || true
  done < <(git ls-files -z --others --exclude-standard)
fi
[ "$nskipped" -le 10 ] || skipped="$skipped, +$((nskipped - 10)) more"

files="$(awk 'END {print NR}' "$work/numstat")"
lines="$(awk '{ if ($1 ~ /^[0-9]+$/) s += $1; if ($2 ~ /^[0-9]+$/) s += $2 } END {print s + 0}' "$work/numstat")"
if [ -n "$max" ] && [ "$files" -gt "$max" ]; then
  echo "base.sh: diff vs $base has $files files: pass the base this branch targets" >&2; exit 4
fi

{
  echo "base: $base"
  echo "head: $head_label"
  echo "merge-base: $mb"
  echo "files: $files"
  echo "lines: $lines"
  echo "untracked: $untracked"
  echo "skipped: ${skipped:-none}"
} > "$work/summary"

if [ -n "$sub" ]; then
  dir="$("$HERE/ovo-dir.sh" "$sub")" || exit 2
  for f in diff.patch target.txt; do [ ! -L "$dir/$f" ] || die "refusing: $dir/$f is a symbolic link"; done
  {
    cat "$work/summary"
    echo "patch-lines: $(awk 'END {print NR}' "$work/patch")"
    echo
    echo "## files"
    awk -F'\t' '{ p = $3; sub(/^\/dev\/null => /, "", p); print $1 " " $2 " " p }' "$work/numstat"
    echo
    echo "## functions"
    awk '/^\+\+\+ b\// { p = substr($0, 7) }
         /^@@ / { c = $0; sub(/^@@ [^@]* @@ ?/, "", c); if (c != "" && !seen[p ": " c]++) print p ": " c }' "$work/patch" | head -n 200
  } > "$work/target"
  mv "$work/patch" "$dir/diff.patch"
  mv "$work/target" "$dir/target.txt"
  cat "$work/summary"
  echo "patch: $dir/diff.patch"
else
  cat "$work/summary"
fi
