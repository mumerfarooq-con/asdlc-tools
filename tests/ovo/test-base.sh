#!/usr/bin/env bash
# base.sh: the base (origin/HEAD or given), the merge-base, and the change: the working tree with
# untracked files, or a head ref; secret-looking untracked files skipped and named.
. "$(dirname "$0")/helpers.sh"
BS="$OS/base.sh"
val() { printf '%s\n' "$OUT" | sed -n "s/^$1: //p"; }

# A repo on a feature branch with a staged, an unstaged, a tracked .env and two untracked changes.
change() {
  fixture_repo "$@"
  printf 'def foo():\n    return 1\n\n\ndef bar():\n    x = 1\n    return x\n' > app.py
  printf 'API_URL=https://old.example.com\n' > .env
  printf '*.log\n' > .gitignore
  git add -A; git commit -qm base
  git update-ref refs/remotes/origin/main HEAD
  git checkout -qb feature/x
  printf 'def foo():\n    return 1\n\n\ndef bar():\n    x = 2\n    return x\n' > app.py; git add app.py
  printf 'API_URL=https://new.example.com\n' > .env
  printf 'new module\n' > new.py
  printf 'SECRET=1\n' > .env.local; mkdir -p deploy; printf 'k\n' > deploy/site.pem
  printf 'noise\n' > debug.log
  mkdir -p nested; (cd nested && git init -q)
}

t "default base is origin/HEAD; the working tree counts staged, unstaged and untracked files"
change
run "$BS"
assert_eq "$CODE" "0" "exit"
assert_eq "$(val base)" "origin/main" "base"
assert_eq "$(val head)" "feature/x (working tree)" "head"
assert_eq "$(val merge-base)" "$(git rev-parse origin/main)" "merge-base"
assert_eq "$(val files)" "3" "files: app.py, .env, new.py"
assert_eq "$(val untracked)" "1" "untracked: new.py"
assert_eq "$(val lines)" "5" "lines: 2 + 2 + 1"
assert_eq "$(val skipped)" ".env.local, deploy/site.pem" "skipped secret-looking untracked files"
assert_not_contains "$OUT" "patch:" "no patch without --write"

t "--write: diff.patch and target.txt in .ovo/<sub>; tracked .env in, untracked secrets, ignored files and nested repos out"
before="$(git status --porcelain)"
run "$BS" --write impact/t1
assert_eq "$CODE" "0" "exit"
D="$FR/.ovo/impact/t1"
assert_eq "$(val patch)" "$D/diff.patch" "patch path"
P="$(cat "$D/diff.patch")"
assert_contains "$P" "+API_URL=https://new.example.com" "a tracked .env change is reviewed (critic 11)"
assert_contains "$P" "+++ b/new.py" "untracked file as a new-file diff"
assert_contains "$P" "-    x = 1" "staged change"
assert_not_contains "$P" "SECRET=1" "untracked .env.local left out"
assert_not_contains "$P" "site.pem" "untracked pem left out"
assert_not_contains "$P" "noise" "ignored file left out"
assert_not_contains "$P" "nested" "nested repo left out"
TT="$(cat "$D/target.txt")"
for k in "base: origin/main" "head: feature/x (working tree)" "files: 3" "lines: 5" "skipped: .env.local, deploy/site.pem" "## files" "1 0 new.py" "## functions" "app.py: def foo():"; do
  assert_contains "$TT" "$k" "target.txt has '$k'"
done
assert_contains "$TT" "merge-base: $(git rev-parse origin/main)" "target.txt merge-base"
assert_eq "$(git status --porcelain)" "$before" "git status unchanged: only .ovo was written"
assert_eq "$(git check-ignore -q "$D/diff.patch" && echo ignored)" "ignored" "and it ignores itself"
assert_eq "$(ls -A "$FR/.ovo/tmp")" "" "no scratch left"

t "--write: diff.numbered numbers each line as in its file (not its place in diff.patch); diff.patch is git's patch, byte for byte"
fixture_repo
awk 'BEGIN { for (i = 1; i <= 120; i++) printf "x%d = %d\n", i, i }' > deep.py
awk 'BEGIN { for (i = 1; i <= 20; i++) printf "def u%d():\n    return %d\n", i, i }' > util.py
printf 'one\ntwo\nthree\n' > legacy.py
printf 'a\nb\nc' > eof.txt
printf '\211PNG\r\n\032\n\000\001' > logo.png
git add -A; git commit -qm base; git update-ref refs/remotes/origin/main HEAD
# Two hunks deep in deep.py (lines 10-11 removed; 100 changed and two lines added), a rename with an
# edit, a deleted file, a changed binary, a last line without a newline, and an untracked file
# whose name has a space (git ends its +++ line with a tab).
awk 'NR == 10 || NR == 11 { next } NR == 100 { print "x100 = \"changed\""; print "x100b = 1"; print "x100c = 2"; next } { print }' deep.py > d; mv d deep.py
git mv util.py helpers.py; sed 's/return 15$/return 150/' helpers.py > h; mv h helpers.py
git rm -q legacy.py
printf 'a\nb\nC\nd' > eof.txt
printf '\211PNG\r\n\032\n\000\002' > logo.png
mkdir -p pkg; printf 'first\nsecond\n' > 'pkg/new file.py'
run "$BS" --write review/n1
assert_eq "$CODE" "0" "exit"
D="$FR/.ovo/review/n1"; N="$(cat "$D/diff.numbered")"
assert_eq "$(val numbered)" "$D/diff.numbered" "numbered path"
mb="$(git merge-base origin/main HEAD)"; EXP="$(mktemp)"; SANDBOXES+=("$EXP")
{ git -c core.quotepath=off diff --no-color --no-ext-diff --no-textconv "$mb"
  git -c core.quotepath=off diff --no-color --no-ext-diff --no-textconv --no-index -- /dev/null 'pkg/new file.py'; } > "$EXP"
cmp -s "$D/diff.patch" "$EXP" && ok || nok "diff.patch is not git's patch"
# num <path> <patch line>: the left column of that line's row under "=== <path>".
num() { awk -v f="$1" -v l="$2" '/^=== / { cur = (substr($0, 5) == f || index($0, "=== " f " (") == 1); next }
                                  cur && substr($0, 9) == l { n = substr($0, 1, 7); gsub(/ /, "", n); print n; exit }' "$D/diff.numbered"; }
assert_eq "$(num deep.py '+x100b = 1')" "99" "an added line deep in the file"
assert_eq "$(sed -n 99p deep.py)" "x100b = 1" "line 99 of deep.py"
assert_eq "$(grep -n '^+x100b = 1$' "$D/diff.patch" | cut -d: -f1 | grep -cx 99)" "0" "its place in diff.patch is not 99"
assert_eq "$(num deep.py ' x101 = 101')" "101" "a context line after the second hunk's change"
assert_eq "$(num deep.py ' x12 = 12')" "10" "a context line after the first hunk's deletion"
assert_eq "$(num deep.py '-x10 = 10')" "-10" "a removed line: -N, its number in the old file"
assert_eq "$(git show "$mb:deep.py" | sed -n 10p)" "x10 = 10" "line 10 of the old deep.py"
assert_contains "$N" "@@ -7,8 +7,6 @@ x6 = 6" "the first hunk's header"
assert_contains "$N" "@@ -97,7 +95,9 @@ x96 = 96" "the second hunk's header"
assert_eq "$(num eof.txt '+d')" "4" "a last line without a newline"
assert_eq "$(num eof.txt '-c')" "-3" "a removed last line without a newline"
assert_eq "$(grep -cx '        \\ No newline at end of file' "$D/diff.numbered")" "2" "no-newline markers have a blank column"
assert_eq "$(num helpers.py '+    return 150')" "30" "a renamed file's change"
assert_eq "$(num legacy.py '-three')" "-3" "a deleted file's line"
assert_eq "$(num 'pkg/new file.py' '+second')" "2" "an untracked file's line"
for h in "=== deep.py" "=== helpers.py (renamed from util.py)" "=== legacy.py (deleted)" "=== logo.png (binary)" "=== pkg/new file.py (new file)"; do
  assert_eq "$(grep -cxF "$h" "$D/diff.numbered")" "1" "header: $h"
done
assert_contains "$N" "$(printf '=== logo.png (binary)\n\n=== pkg/new file.py (new file)')" "no rows under a binary file"
# Every row's number names that line in its file: at head for + and context rows, at the merge-base for -N.
checked=0; bad=""
while IFS= read -r row; do
  case "$row" in
    "=== "*) f="${row#=== }"; f="${f%% (*}"
             case "$row" in *"(renamed from "*) o="${row#*renamed from }"; o="${o%)}" ;; *) o="$f" ;; esac
             continue ;;
  esac
  n="$(printf '%s' "${row:0:7}" | tr -d ' ')"
  case "$n" in
    -[0-9]*) [ "$(git show "$mb:$o" | sed -n "${n#-}p")" = "${row:9}" ] || bad="$bad $o:$n" ;;
    ''|*[!0-9]*) continue ;;
    *) [ "$(sed -n "${n}p" "$f")" = "${row:9}" ] || bad="$bad $f:$n" ;;
  esac
  checked=$((checked + 1))
done < "$D/diff.numbered"
assert_eq "$bad" "" "rows whose number is not the line's number in its file"
assert_eq "$checked" "36" "rows checked: 18 in deep.py, 5 eof.txt, 8 helpers.py, 3 legacy.py, 2 pkg/new file.py"

t "a clean tree has 0 files; an explicit base works without origin/HEAD"
fixture_repo --no-head
run "$BS"; assert_eq "$CODE" "2" "no origin/HEAD"; assert_contains "$ERR" "no default branch: pass a base" "message"
run "$BS" main; assert_eq "$CODE" "0" "explicit base"; assert_eq "$(val files)" "0" "clean"
run "$BS" origin/main; assert_eq "$(val base)" "origin/main" "remote-tracking base"

t "--head: the merge-base up to that ref, nothing local"
change
git commit -qm feature; printf 'local only\n' > local.txt
run "$BS" --head feature/x main
assert_eq "$CODE" "0" "exit"
assert_eq "$(val head)" "feature/x" "head label"
assert_eq "$(val files)" "1" "only the committed app.py"
assert_eq "$(val untracked)" "0" "no untracked in head mode"
assert_eq "$(val skipped)" "none" "nothing skipped"

t "--max-files: over the cap exits 4 and writes nothing"
change
run "$BS" --max-files 2 --write review/big
assert_eq "$CODE" "4" "exit"
assert_contains "$ERR" "diff vs origin/main has 3 files: pass the base this branch targets" "message"
[ -e "$FR/.ovo/review/big/diff.patch" ] && nok "a patch was written" || ok
[ -e "$FR/.ovo/review/big/diff.numbered" ] && nok "a numbered patch was written" || ok
run "$BS" --max-files 3 --write review/big; assert_eq "$CODE" "0" "at the cap"

t "bad input refused"
change
for bad in "--head -x" "-x" "--max-files x" "--max-files" "--write" "main extra" "no-such-ref"; do
  # shellcheck disable=SC2086
  run "$BS" $bad; assert_eq "$CODE" "2" "refused: $bad"
done
run "$BS" --head no-such-ref main; assert_eq "$CODE" "2" "unknown head"
run "$BS" --write ../x; assert_eq "$CODE" "2" "a bad --write sub"
ln -s /dev/null "$("$OS/ovo-dir.sh" impact/ln)/diff.patch"
run "$BS" --write impact/ln; assert_eq "$CODE" "2" "a symlinked diff.patch"
ln -s /dev/null "$("$OS/ovo-dir.sh" impact/ln2)/diff.numbered"
run "$BS" --write impact/ln2; assert_eq "$CODE" "2" "a symlinked diff.numbered"
NR="$(mktemp -d)"; SANDBOXES+=("$NR"); cd "$NR"
run "$BS" main; assert_eq "$CODE" "2" "outside a repo"; assert_contains "$ERR" "run inside a git repo" "message"

finish
