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
NR="$(mktemp -d)"; SANDBOXES+=("$NR"); cd "$NR"
run "$BS" main; assert_eq "$CODE" "2" "outside a repo"; assert_contains "$ERR" "run inside a git repo" "message"

finish
