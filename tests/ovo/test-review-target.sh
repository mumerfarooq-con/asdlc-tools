#!/usr/bin/env bash
# review-target.sh: what /ovo:review reviews. Default working tree, branch mode with a fetch, PR
# URLs through fake curl and gh (no network), the size guard, and the token's path.
. "$(dirname "$0")/helpers.sh"
RT="$OS/review-target.sh"
FB="$OVO_FAKEBIN"
TOKEN="tok-SENTINEL-123"
HINT='pass the branch: /ovo:review <branch> [base]'
export FAKECURL_LOG FAKECURL_STDIN_LOG

# A repo with a real bare origin, a committed feature/x branch pushed there, and a local change.
remote_repo() {
  fixture_repo --remote
  git checkout -qb feature/x
  printf 'def pay(amount):\n    return amount\n' > billing.py; git add -A; git commit -qm feature
  git push -q origin feature/x 2>/dev/null
  git checkout -q main
}
fresh_logs() {
  FAKECURL_LOG="$(mktemp)"; FAKECURL_STDIN_LOG="$(mktemp)"; FAKEGH_LOG="$(mktemp)"
  SANDBOXES+=("$FAKECURL_LOG" "$FAKECURL_STDIN_LOG" "$FAKEGH_LOG"); export FAKEGH_LOG
}
calls() { grep -c '^--end--$' "$FAKECURL_LOG" || true; }
bb_body() {  # <source branch> <dest branch> [<source repo>]
  printf '{"source":{"branch":{"name":"%s"},"repository":{"full_name":"%s"}},"destination":{"branch":{"name":"%s"},"repository":{"full_name":"acme/widgets"}}}' \
    "$1" "${3:-acme/widgets}" "$2"
}
# A PATH with the tools the scripts use and no gh (CI runners ship gh in /usr/bin).
nogh_path() {
  local d c; d="$(mktemp -d)"; SANDBOXES+=("$d")
  for c in bash sh git jq sed tr cut awk mktemp mv rm cat date head tail grep sort wc dirname basename ls mkdir chmod env uname tee; do
    [ -n "$(type -P "$c")" ] && ln -s "$(type -P "$c")" "$d/$c"
  done
  ln -s "$FB/curl" "$d/curl"
  printf '%s' "$d"
}

t "default: the working tree vs origin/HEAD, untracked files in, a secret-looking one left out and named"
fixture_repo
printf 'API_URL=https://old.example.com\n' > .env; git add -A; git commit -qm env; git update-ref refs/remotes/origin/main HEAD
printf 'API_URL=https://new.example.com\n' > .env
printf 'print(1)\n' > new.py; printf 'K=1\n' > .env.prod
run "$RT" r1
assert_eq "$CODE" "0" "exit"
assert_eq "$(printf '%s\n' "$OUT" | sed -n 1p)" "Reviewing main (working tree) against origin/main, 2 files (3 lines); left out secret-looking untracked files: .env.prod" "first line"
assert_eq "$(printf '%s\n' "$OUT" | sed -n 2p)" "patch: $FR/.ovo/review/r1/diff.patch" "second line"
assert_eq "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" "2" "only two lines"
P="$(cat .ovo/review/r1/diff.patch)"
assert_contains "$P" "+print(1)" "untracked file included"
assert_contains "$P" "+API_URL=https://new.example.com" "tracked .env change included"
assert_not_contains "$P" "K=1" "untracked secret left out"
assert_contains "$(cat .ovo/review/r1/target.txt)" "skipped: .env.prod" "target.txt names it"
for k in "base: origin/main" "merge-base: " "files: 2" "lines: 3"; do assert_contains "$(cat .ovo/review/r1/target.txt)" "$k" "target.txt has $k"; done

t "no origin/HEAD: exit 2, pass a base"
fixture_repo --no-head
run "$RT" r1; assert_eq "$CODE" "2" "exit"; assert_contains "$ERR" "no default branch: pass a base" "message"
run "$RT" r1 some-branch; assert_eq "$CODE" "2" "branch mode without a base"; assert_contains "$ERR" "no default branch: pass a base" "message"

t "size guard: more than 60 changed files exits 4 and writes no patch; 60 is fine"
fixture_repo
for i in $(seq 1 61); do echo "$i" > "f$i.txt"; done
run "$RT" big; assert_eq "$CODE" "4" "61 files"
assert_contains "$ERR" "diff vs origin/main has 61 files: pass the base this branch targets" "message"
[ -e .ovo/review/big/diff.patch ] && nok "a patch was written" || ok
rm f61.txt; run "$RT" big; assert_eq "$CODE" "0" "60 files"

t "branch mode: fetches, then diffs origin/<branch> against the base; nothing local"
remote_repo
git branch -qD feature/x; git update-ref -d refs/remotes/origin/feature/x
printf 'local noise\n' > local.txt
run "$RT" r2 feature/x main
assert_eq "$CODE" "0" "exit"
assert_eq "$(printf '%s\n' "$OUT" | sed -n 1p)" "Reviewing origin/feature/x against origin/main, 1 files (2 lines)" "first line"
assert_not_contains "$ERR" "could not fetch" "fetch worked"
assert_not_contains "$(cat .ovo/review/r2/diff.patch)" "local noise" "no working tree"
assert_eq "$(git status --porcelain)" "?? local.txt" "git status: only the user's file"

t "branch mode: a failed fetch warns and uses local refs"
fixture_repo; git checkout -qb feature/y; echo y > y.txt; git add -A; git commit -qm y; git checkout -q main
run "$RT" r3 feature/y
assert_eq "$CODE" "0" "exit"
assert_contains "$ERR" "warn: could not fetch feature/y and main from origin; using local refs" "warning"
assert_contains "$OUT" "Reviewing feature/y against origin/main, 1 files" "local branch vs origin/main"
run "$RT" r3 no-such-branch; assert_eq "$CODE" "2" "an unknown branch"
for bad in -x "a..b" "a b" "x~1"; do run "$RT" r3 "$bad"; assert_eq "$CODE" "2" "bad branch [$bad]"; done
run "$RT" r3 feature/y -main; assert_eq "$CODE" "2" "bad base"

t "bad URLs are refused before any request"
fixture_repo; fresh_logs; export BITBUCKET_TOKEN="$TOKEN"
for u in http://bitbucket.org/acme/widgets/pull-requests/1 https://bitbucket.org.evil.example/acme/widgets/pull-requests/1 \
         https://evil.example/acme/widgets/pull-requests/1 https://bitbucket.org/acme/widgets/pull-requests/abc \
         https://bitbucket.org/-x/widgets/pull-requests/1 https://bitbucket.org/acme/../pull-requests/1 \
         https://bitbucket.org/acme/widgets/pull-requests/1?x=1 https://bitbucket.org/acme/wid%2Fgets/pull-requests/1 \
         "https://bitbucket.org/acme/widgets/pull-requests/1 x" http://github.com/acme/widgets/pull/1 https://github.com/acme/widgets/pull/x; do
  PATH="$FB:$PATH" run "$RT" r4 "$u"; assert_eq "$CODE" "2" "refused: $u"
done
assert_eq "$(calls)" "0" "curl never called"
PATH="$FB:$PATH" run "$RT" r4 http://bitbucket.org/acme/widgets/pull-requests/1
assert_contains "$ERR" "not a Bitbucket or GitHub PR URL (https only)" "http:// is refused as such"
PATH="$FB:$PATH" run "$RT" r4 https://bitbucket.org/acme/widgets/pull-requests/1 main; assert_eq "$CODE" "2" "a URL takes no base"
unset BITBUCKET_TOKEN

t "Bitbucket URL without BITBUCKET_TOKEN: exit 2 with the pass-the-branch hint, no request"
fixture_repo; fresh_logs
PATH="$FB:$PATH" run "$RT" r5 https://bitbucket.org/acme/widgets/pull-requests/7
assert_eq "$CODE" "2" "exit"; assert_contains "$ERR" "needs BITBUCKET_TOKEN; $HINT" "hint"
assert_eq "$(calls)" "0" "no request"

t "Bitbucket URL: one GET to api.bitbucket.org, https only, no redirects, 30 s; the token on stdin, never on argv or in curl's env"
remote_repo; git branch -qD feature/x; git update-ref -d refs/remotes/origin/feature/x; fresh_logs
export BITBUCKET_TOKEN="$TOKEN"
FAKECURL_BODY="$(bb_body feature/x main)" PATH="$FB:$PATH" run "$RT" r6 https://bitbucket.org/acme/widgets/pull-requests/7/overview
assert_eq "$CODE" "0" "exit"
assert_contains "$OUT" "Reviewing origin/feature/x against origin/main, 1 files" "resolved to the PR's branches"
assert_eq "$(calls)" "1" "one request"
A="$(cat "$FAKECURL_LOG")"
assert_not_contains "$A" "$TOKEN" "token not on argv"
assert_contains "$A" "env: BITBUCKET_TOKEN= BITBUCKET_EMAIL=" "token not in curl's environment"
assert_eq "$(grep '^https://' "$FAKECURL_LOG")" "https://api.bitbucket.org/2.0/repositories/acme/widgets/pullrequests/7" "the only URL"
for a in --proto =https --max-redirs --max-time 30 --config; do assert_contains "$A" "$a" "argv has $a"; done
assert_eq "$(grep -cxE -- '-L|--location' "$FAKECURL_LOG" || true)" "0" "no redirect following"
assert_contains "$(cat "$FAKECURL_STDIN_LOG")" "header = \"Authorization: Bearer $TOKEN\"" "Bearer on stdin"
assert_eq "$(ls -A .ovo/review/r6 | tr '\n' ' ')" "diff.patch target.txt " "the PR body is not kept"

t "Bitbucket: 401 retries once with Basic when BITBUCKET_EMAIL is set; otherwise stops"
fresh_logs
BITBUCKET_EMAIL=dev@example.com FAKECURL_CODES="401 200" FAKECURL_BODY="$(bb_body feature/x main)" PATH="$FB:$PATH" run "$RT" r7 https://bitbucket.org/acme/widgets/pull-requests/7
assert_eq "$CODE" "0" "exit"; assert_eq "$(calls)" "2" "two requests"
assert_contains "$(cat "$FAKECURL_STDIN_LOG")" "user = \"dev@example.com:$TOKEN\"" "Basic on stdin"
assert_not_contains "$(cat "$FAKECURL_LOG")" "$TOKEN" "token not on argv"
assert_not_contains "$(cat "$FAKECURL_LOG")" "dev@example.com" "email not on argv"
fresh_logs
FAKECURL_CODES="401" PATH="$FB:$PATH" run "$RT" r7 https://bitbucket.org/acme/widgets/pull-requests/7
assert_eq "$CODE" "2" "401 without an email"; assert_eq "$(calls)" "1" "no retry"; assert_contains "$ERR" "HTTP 401 for that PR; $HINT" "hint"
fresh_logs
FAKECURL_CODES="404" PATH="$FB:$PATH" run "$RT" r7 https://bitbucket.org/acme/widgets/pull-requests/7
assert_eq "$CODE" "2" "404"; assert_contains "$ERR" "$HINT" "hint"
fresh_logs
FAKECURL_EXIT=7 PATH="$FB:$PATH" run "$RT" r7 https://bitbucket.org/acme/widgets/pull-requests/7
assert_eq "$CODE" "2" "curl failed"; assert_contains "$ERR" "could not reach api.bitbucket.org; $HINT" "hint"

t "Bitbucket: a fork PR, odd branch names and a token Ovo won't send are refused"
fresh_logs
FAKECURL_BODY="$(bb_body feature/x main someone/widgets)" PATH="$FB:$PATH" run "$RT" r8 https://bitbucket.org/acme/widgets/pull-requests/7
assert_eq "$CODE" "2" "fork"; assert_contains "$ERR" "this PR comes from a fork; $HINT" "fork hint"
FAKECURL_BODY="$(bb_body -x main)" PATH="$FB:$PATH" run "$RT" r8 https://bitbucket.org/acme/widgets/pull-requests/7
assert_eq "$CODE" "2" "a source branch starting with -"
FAKECURL_BODY="$(bb_body '' main)" PATH="$FB:$PATH" run "$RT" r8 https://bitbucket.org/acme/widgets/pull-requests/7
assert_eq "$CODE" "2" "an empty source branch"; assert_contains "$ERR" "could not read the PR's branches" "message"
[ -e .ovo/review/r8/diff.patch ] && nok "an empty branch fell through to the working tree" || ok
FAKECURL_BODY='not json' PATH="$FB:$PATH" run "$RT" r8 https://bitbucket.org/acme/widgets/pull-requests/7
assert_eq "$CODE" "2" "a body that is not JSON"
fresh_logs
BITBUCKET_TOKEN='a"b' PATH="$FB:$PATH" run "$RT" r8 https://bitbucket.org/acme/widgets/pull-requests/7
assert_eq "$CODE" "2" "a token with a quote"; assert_eq "$(calls)" "0" "not sent"
unset BITBUCKET_TOKEN

t "GitHub URL: gh resolves the branches; no gh, a gh failure or a fork gives the hint"
fresh_logs
FAKEGH_OUT='{"headRefName":"feature/x","baseRefName":"main","isCrossRepository":false}' PATH="$FB:$PATH" run "$RT" r9 https://github.com/acme/widgets/pull/12
assert_eq "$CODE" "0" "exit"; assert_contains "$OUT" "Reviewing origin/feature/x against origin/main" "resolved"
assert_eq "$(head -n 4 "$FAKEGH_LOG" | tr '\n' ' ')" "pr view https://github.com/acme/widgets/pull/12 --json " "gh pr view only"
FAKEGH_OUT='{"headRefName":"feature/x","baseRefName":"main","isCrossRepository":true}' PATH="$FB:$PATH" run "$RT" r9 https://github.com/acme/widgets/pull/12
assert_eq "$CODE" "2" "fork"; assert_contains "$ERR" "fork; $HINT" "fork hint"
FAKEGH_EXIT=1 PATH="$FB:$PATH" run "$RT" r9 https://github.com/acme/widgets/pull/12
assert_eq "$CODE" "2" "gh failed"; assert_contains "$ERR" "$HINT" "hint"
NOGH="$(nogh_path)"
PATH="$NOGH" run "$RT" r9 https://github.com/acme/widgets/pull/12
assert_eq "$CODE" "2" "no gh"; assert_contains "$ERR" "needs the gh CLI; $HINT" "hint"

t "usage and ids"
fixture_repo
run "$RT"; assert_eq "$CODE" "2" "no id"
run "$RT" ../x; assert_eq "$CODE" "2" "bad id"
run "$RT" r1 a b c; assert_eq "$CODE" "2" "too many arguments"
assert_eq "$(git status --porcelain)" "" "git status clean"

finish
