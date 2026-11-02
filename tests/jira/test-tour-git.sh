#!/usr/bin/env bash
# tour-git.sh: each fixed form on a sandbox repo with an origin, and its refusals.
. "$(dirname "$0")/helpers.sh"
TG="$SHARED/tour-git.sh"

# origin holds main and feature/x; the clone starts with main only.
O="$(cd "$(mktemp -d)" && pwd -P)"; SANDBOXES+=("$O")
git init -q -b main "$O" 2>/dev/null || { git init -q "$O"; git -C "$O" checkout -q -b main; }
( cd "$O" && mkdir -p app && printf 'one\ntwo\n' > app/a.py && echo base > README.md && git add -A && git commit -qm base \
  && git checkout -qb feature/x && printf 'one\ntwo\nthree\n' > app/a.py && git add -A && git commit -qm c1 )
C1="$(git -C "$O" rev-parse feature/x)"
( cd "$O" && echo more >> app/a.py && echo n > app/b.py && git add -A && git commit -qm c2 \
  && git checkout -q main && echo side > side.txt && git add -A && git commit -qm side )
sandbox
git remote add origin "$O"
git fetch -q origin main
git checkout -q -b work origin/main
printf '.asdlc/\n' > .git/info/exclude

t "head before fetch"
run "$TG" head feature/x; assert_eq "$CODE" "1" "no remote-tracking ref yet"

t "fetch and head"
run "$TG" fetch feature/x; assert_eq "$CODE" "0" "fetch exit"
run "$TG" head feature/x
assert_eq "$CODE" "0" "head exit"; assert_eq "$OUT" "$(git -C "$O" rev-parse feature/x)" "sha40 of origin/feature/x"

t "show: the head version, numbered"
run "$TG" show feature/x app/a.py
assert_eq "$CODE" "0" "exit"
assert_contains "$OUT" "origin/feature/x:app/a.py:3:three" "numbered line"
assert_contains "$OUT" "origin/feature/x:app/a.py:4:more" "head, not the first commit"

t "diff: merge-base diff, optional path"
run "$TG" diff main feature/x
assert_eq "$CODE" "0" "exit"; assert_contains "$OUT" "+three" "branch change"; assert_contains "$OUT" "app/b.py" "all files"
assert_not_contains "$OUT" "side.txt" "main's own change is not in the merge-base diff"
run "$TG" diff main feature/x app/b.py
assert_contains "$OUT" "app/b.py" "the path"; assert_not_contains "$OUT" "app/a.py" "only that path"

t "changed: names since a sha"
run "$TG" changed "$C1" feature/x
assert_eq "$CODE" "0" "exit"; assert_contains "$OUT" "app/a.py" "a.py changed after c1"; assert_contains "$OUT" "app/b.py" "b.py added after c1"
assert_not_contains "$OUT" "README.md" "untouched file"

t "refusals"
run "$TG" head -x;                         assert_eq "$CODE" "2" "leading - ref"
run "$TG" fetch --upload-pack=x;           assert_eq "$CODE" "2" "option-like fetch ref"
run "$TG" show feature/x -p;               assert_eq "$CODE" "2" "leading - path"
run "$TG" diff main feature/x --output=x;  assert_eq "$CODE" "2" "leading - diff path"
run "$TG" diff -x feature/x;               assert_eq "$CODE" "2" "leading - target"
run "$TG" head "bad..ref";                 assert_eq "$CODE" "2" "bad ref name"
run "$TG" head "a b";                      assert_eq "$CODE" "2" "ref with a space"
run "$TG" head '@{-1}';                    assert_eq "$CODE" "2" "reflog ref"
run "$TG" show feature/x "$(printf 'a\tb')"; assert_eq "$CODE" "2" "control character in a path"
run "$TG" show feature/x "$(printf 'a\nb')"; assert_eq "$CODE" "2" "newline in a path"
run "$TG" changed notasha feature/x;       assert_eq "$CODE" "2" "not a sha40"
run "$TG" changed -p feature/x;            assert_eq "$CODE" "2" "option as sha"
run "$TG" log main;                        assert_eq "$CODE" "2" "unknown form"
run "$TG";                                 assert_eq "$CODE" "2" "no form"
run "$TG" head;                            assert_eq "$CODE" "2" "missing argument"
run "$TG" show feature/x app/a.py extra;   assert_eq "$CODE" "2" "too many arguments"
run "$TG" show feature/x ":(top)README.md"; assert_not_contains "$OUT" "base" "pathspec magic is literal"

t "read-only: the working tree and local refs are unchanged"
assert_eq "$(git status --porcelain)" "" "clean tree"
assert_eq "$(git branch --format='%(refname)' | tr '\n' ' ')" "refs/heads/work " "no local branch created"

finish
