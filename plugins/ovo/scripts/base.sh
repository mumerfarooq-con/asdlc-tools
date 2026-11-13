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
# from git's hunk headers), and adds "patch: <path>" to the output. It also writes
# .ovo/<sub>/diff.numbered, the same patch with each line's number in its file (see numbered()),
# and adds "numbered: <path>". --max-files <n>: more changed files than that exits 4 and writes
# nothing.
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

# The patch with line numbers, so an agent cites path:N with no arithmetic on hunk headers: per file
# "=== <path> (<new file, deleted, renamed from ..., binary>)", each hunk's @@ line, then every patch
# line behind a 7-wide column: the new file's line number for + and context lines, -N (the old
# file's) for - lines, blank for "\ No newline at end of file". The hunk's counts say where its
# body ends, so a removed line that starts with "--" is still a removed line.
numbered() {  # <patch>
  awk '
    function unq(p) { sub(/\t$/, "", p); if (p ~ /^".*"$/) p = substr(p, 2, length(p) - 2); return p }
    function guess(r,   h, x, y) {  # "a/P b/P": P (no ---/+++ lines for a binary or mode-only change)
      h = int((length(r) - 1) / 2); x = unq(substr(r, 1, h)); y = unq(substr(r, h + 2))
      return (substr(x, 3) == substr(y, 3)) ? substr(y, 3) : y
    }
    function fileline(  t, p) {  # the file line, once, before its first hunk
      if (!infile || said) return
      t = ""
      if (isnew) t = t ", new file"
      if (isdel) t = t ", deleted"
      if (from != "") t = t ", " how " from " from
      if (mode != "") t = t ", mode " mode
      if (bin) t = t ", binary"
      p = np != "" ? np : (op != "" ? op : gp)
      printf "%s=== %s%s\n", (nfile++ ? "\n" : ""), p, (t == "" ? "" : " (" substr(t, 3) ")")
      said = 1
    }
    BEGIN {
      print "# The patch with line numbers. Left column: the line number in the new file (+ and unchanged"
      print "# lines), or -N, the line number in the old file (- lines). Cite path:N from this column; for"
      print "# a removed line, cite the nearest line without a minus."
    }
    /^\\/ { printf "%7s %s\n", "", $0; next }
    (ol > 0 || nl > 0) && /^[-+ ]/ {
      if ($0 ~ /^-/) { printf "%7s %s\n", "-" on, $0; on++; ol--; next }
      printf "%7d %s\n", nn, $0; nn++; nl--
      if ($0 ~ /^ /) { on++; ol-- }
      next
    }
    /^diff --git / {
      fileline(); infile = 1; said = 0; isnew = isdel = bin = 0; ol = nl = 0
      np = op = from = how = mode = ""; gp = guess(substr($0, 12)); next
    }
    /^new file mode / { isnew = 1; next }
    /^deleted file mode / { isdel = 1; next }
    /^old mode / { mode = substr($0, 10); next }
    /^new mode / { mode = mode " -> " substr($0, 10); next }
    /^rename from / { how = "renamed"; from = unq(substr($0, 13)); next }
    /^copy from / { how = "copied"; from = unq(substr($0, 11)); next }
    /^rename to / { np = unq(substr($0, 11)); next }
    /^copy to / { np = unq(substr($0, 9)); next }
    /^Binary files / { bin = 1; next }
    /^--- / { p = unq(substr($0, 5)); if (p != "/dev/null") { sub(/^a\//, "", p); op = p }; next }
    /^\+\+\+ / { p = unq(substr($0, 5)); if (p != "/dev/null") { sub(/^b\//, "", p); np = p }; next }
    /^@@ / {
      fileline(); split($0, f, " ")
      split(substr(f[2], 2), a, ","); on = a[1] + 0; ol = (2 in a) ? a[2] + 0 : 1
      split(substr(f[3], 2), a, ","); nn = a[1] + 0; nl = (2 in a) ? a[2] + 0 : 1
      print; next
    }
    END { fileline() }' "$1"
}

if [ -n "$sub" ]; then
  dir="$("$HERE/ovo-dir.sh" "$sub")" || exit 2
  for f in diff.patch diff.numbered target.txt; do [ ! -L "$dir/$f" ] || die "refusing: $dir/$f is a symbolic link"; done
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
  numbered "$work/patch" > "$work/numbered"
  mv "$work/patch" "$dir/diff.patch"
  mv "$work/numbered" "$dir/diff.numbered"
  mv "$work/target" "$dir/target.txt"
  cat "$work/summary"
  echo "patch: $dir/diff.patch"
  echo "numbered: $dir/diff.numbered"
else
  cat "$work/summary"
fi
