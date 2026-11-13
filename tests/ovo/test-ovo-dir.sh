#!/usr/bin/env bash
# ovo-dir.sh: <top>/.ovo/<sub>, mode 700, a self-ignoring .gitignore, links and non-repos refused.
. "$(dirname "$0")/helpers.sh"
OD="$OS/ovo-dir.sh"
perm() { ls -ld "$1" | cut -c1-10; }

t "prints <top>/.ovo/<sub>, creates it with mode 700, from any subdirectory"
fixture_repo
mkdir -p src/deep; cd src/deep
run "$OD" impact/run-1
assert_eq "$CODE" "0" "exit"
assert_eq "$OUT" "$FR/.ovo/impact/run-1" "path"
cd "$FR"
for d in .ovo .ovo/impact .ovo/impact/run-1; do assert_eq "$(perm "$d")" "drwx------" "$d mode"; done

t "the first use writes .ovo/.gitignore = *: the directory ignores itself, git status stays clean"
assert_eq "$(cat .ovo/.gitignore)" "*" ".gitignore content"
echo x > .ovo/impact/run-1/impact.md
assert_eq "$(git status --porcelain)" "" "git status after writing a report"
assert_eq "$(git check-ignore -q .ovo/impact/run-1/impact.md && echo ignored)" "ignored" "report is ignored"
assert_eq "$(git diff --name-only; git ls-files --others --exclude-standard)" "" "no tracked or untracked file outside the ignore"
t "a later use keeps the user's own .gitignore"
printf '*\n!keep\n' > .ovo/.gitignore
run "$OD" review/r2; assert_eq "$CODE" "0" "exit"
assert_eq "$(cat .ovo/.gitignore)" "$(printf '*\n!keep')" "not rewritten"
rm .ovo/.gitignore; run "$OD" review/r2; assert_eq "$(cat .ovo/.gitignore)" "*" "re-created when missing"

t "refuses a symlinked .ovo, .gitignore or part of <sub>, and a non-directory"
fixture_repo; OUTSIDE="$(mktemp -d)"; SANDBOXES+=("$OUTSIDE")
ln -s "$OUTSIDE" .ovo
run "$OD" impact/x; assert_eq "$CODE" "2" "symlinked .ovo"; assert_contains "$ERR" "symbolic link" "message"
assert_eq "$(ls -A "$OUTSIDE")" "" "nothing written through the link"
rm .ovo; mkdir .ovo; ln -s "$OUTSIDE/gi" .ovo/.gitignore
run "$OD" impact/x; assert_eq "$CODE" "2" "symlinked .gitignore"
assert_eq "$(ls -A "$OUTSIDE")" "" "nothing written through the .gitignore link"
rm .ovo/.gitignore; ln -s "$OUTSIDE" .ovo/impact
run "$OD" impact/x; assert_eq "$CODE" "2" "symlinked sub part"; assert_contains "$ERR" "symbolic link" "message"
assert_eq "$(ls -A "$OUTSIDE")" "" "nothing created through the sub link"
rm .ovo/impact; mkdir .ovo/impact; ln -s "$OUTSIDE" .ovo/impact/x
run "$OD" impact/x; assert_eq "$CODE" "2" "symlinked leaf"
rm .ovo/impact/x; echo f > .ovo/impact/x
run "$OD" impact/x; assert_eq "$CODE" "2" "a file where a directory goes"
rm -rf .ovo; echo f > .ovo
run "$OD" impact/x; assert_eq "$CODE" "2" ".ovo is a file"

t "bad <sub> refused"
fixture_repo
for bad in "" ../x x/../y /abs .hidden x/.y "-x" "x//y" "x/" "a b" "$(printf 'a\tb')"; do
  run "$OD" "$bad"; assert_eq "$CODE" "2" "refused: [$(printf '%s' "$bad" | tr -cd '[:print:]')]"
done
run "$OD" a b; assert_eq "$CODE" "2" "two arguments"
assert_eq "$(ls -A)" "$(printf '.git\nREADME.md')" "nothing created for bad input"

t "outside a git work tree: exit 2, run inside a git repo"
NR="$(mktemp -d)"; SANDBOXES+=("$NR"); cd "$NR"
run "$OD" impact/x; assert_eq "$CODE" "2" "exit"; assert_contains "$ERR" "run inside a git repo" "message"
assert_eq "$(ls -A)" "" "nothing written"
cd "$FR/.git"; run "$OD" impact/x; assert_eq "$CODE" "2" "inside .git"

t "--new: <kind>/<branch-slug>-<UTC yyyymmddHHMM>, unique, slug from the branch or a name"
fixture_repo; git checkout -qb "feature/ABC-1+big@change"
run "$OD" impact --new; assert_eq "$CODE" "0" "exit"
id1="$(basename "$OUT")"
if [[ $id1 =~ ^feature-ABC-1-big-change-[0-9]{12}$ ]]; then ok; else nok "id shape: $id1"; fi
assert_eq "$(dirname "$OUT")" "$FR/.ovo/impact" "under the kind"
[ -d "$OUT" ] && ok || nok "created"
run "$OD" impact --new; id2="$(basename "$OUT")"
case "$id2" in "$id1"|"") nok "second id not unique: $id2" ;; *) ok ;; esac
run "$OD" review --new "../../etc/passwd"; assert_eq "$CODE" "0" "a hostile name is slugged"
case "$(basename "$OUT")" in etc-passwd-*) ok ;; *) nok "slug of a hostile name: $(basename "$OUT")" ;; esac
assert_eq "$(dirname "$OUT")" "$FR/.ovo/review" "stays under the kind"
run "$OD" review --new "///"; assert_eq "$CODE" "0" "an empty slug"
case "$(basename "$OUT")" in head-*) ok ;; *) nok "empty slug falls back to head: $(basename "$OUT")" ;; esac
git checkout -q --detach
run "$OD" impact --new; case "$(basename "$OUT")" in detached-*) ok ;; *) nok "detached: $OUT" ;; esac
run "$OD" ../x --new; assert_eq "$CODE" "2" "bad kind"
assert_eq "$(git status --porcelain)" "" "git status clean"

finish
