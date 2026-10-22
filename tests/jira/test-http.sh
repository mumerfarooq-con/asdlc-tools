#!/usr/bin/env bash
# The real HTTP path (no --fixtures): where credentials may go, the curl
# arguments, auth selection and failure messages. A curl stub on PATH records
# every call, so nothing here touches the network.
. "$(dirname "$0")/helpers.sh"
PATH="$ROOT/tests/jira/fakebin:$PATH"
export JIRA_EMAIL=me@example.com JIRA_TOKEN=s3cr3t-value BITBUCKET_TOKEN=bb-s3cr3t-value

# A sandbox whose curl stub log starts empty.
http_sandbox() { sandbox "$@"; export FAKECURL_LOG="$SB/curl.log"; : > "$FAKECURL_LOG"; }
calls() { wc -l < "$FAKECURL_LOG" | tr -d ' '; }                  # how many times curl ran
argv()  { sed -n "${1}p" "$FAKECURL_LOG"; }                       # <n> -> nth call's argv, a JSON array
after() { jq -r --arg o "$1" 'index($o) as $i | if $i == null then "(absent)" else .[$i + 1] end' <<<"$2"; }  # <option> <argv>
has()   { jq -e --arg o "$1" 'index($o) != null' <<<"$2" >/dev/null; }  # <arg> <argv>
assert_arg()    { if has "$1" "$2"; then ok; else nok "argv lacks [$1]: $2"; fi; }
assert_no_arg() { if has "$1" "$2"; then nok "argv has unexpected [$1]: $2"; else ok; fi; }
SEARCH='{"issues":[]}'

# --- (a) MF-1: a bad URL stops everything before curl runs -------------------
for bad in 'http://example.atlassian.net' 'https://evil.example.com' 'https://user@example.atlassian.net' \
           'https://example.atlassian.net/path' 'https://example.atlassian.net?x=1' \
           'https://example.atlassian.net#frag' 'https://example.atlassian.net:80a' \
           'https://example.atlassian.net.evil.example.com' '-K/etc/passwd' 'example.atlassian.net'; do
  t "refused before any request: JIRA_BASE_URL=$bad"
  http_sandbox "JIRA_BASE_URL=$bad"
  run "$S/jira-mine.sh"
  assert_eq "$CODE" "1" "exit"
  assert_contains "$ERR" "JIRA_BASE_URL" "reason"
  assert_eq "$(calls)" "0" "curl calls"
done

t "a foreign host is named, with the opt-in to use and where it belongs"
http_sandbox 'JIRA_BASE_URL=https://evil.example.com'
run "$S/jira-mine.sh"
assert_contains "$ERR" "'evil.example.com'" "host"
assert_contains "$ERR" "export ASDLC_JIRA_ALLOWED_HOSTS=evil.example.com" "opt-in"
assert_contains "$ERR" "never in the repo" "where"

t "setup check: a bad URL is a FAIL line with the reason, no crash, no request"
for bad in 'http://example.atlassian.net' 'https://evil.example.com' 'https://user@example.atlassian.net'; do
  http_sandbox "JIRA_BASE_URL=$bad"
  run "$S/jira-setup.sh" check
  assert_eq "$CODE" "1" "exit for $bad"
  assert_contains "$OUT" "FAIL  JIRA_BASE_URL" "FAIL line for $bad"
  assert_contains "$OUT" "1 check(s) failed." "summary for $bad"
  assert_not_contains "$OUT" "Jira: signed in" "no sign-in for $bad"
  assert_eq "$(calls)" "0" "curl calls for $bad"
done

t "fixture mode refuses a bad URL too"
http_sandbox 'JIRA_BASE_URL=https://evil.example.com'; use_fixtures basic
run "$S/jira-mine.sh"
assert_eq "$CODE" "1" "exit"; assert_contains "$ERR" "ASDLC_JIRA_ALLOWED_HOSTS"
assert_eq "$(requests)" "[]" "no fixture request"

# --- (b) the environment, not the repo, authorises other hosts ---------------
t "a foreign host passes when the environment allows it"
http_sandbox 'JIRA_BASE_URL=https://jira.example.com'
ASDLC_JIRA_ALLOWED_HOSTS=jira.example.com FAKECURL_BODY="$SEARCH" run "$S/jira-mine.sh"
assert_eq "$CODE" "0" "exit"; assert_eq "$(calls)" "1" "curl calls"
assert_eq "$(jq -r '.[-1]' <<<"$(argv 1)")" "https://jira.example.com/rest/api/2/search/jql" "url"

t "allowed hosts: comma list, any case, port kept; other entries don't help"
http_sandbox 'JIRA_BASE_URL=https://JIRA.example.com:8443/'
ASDLC_JIRA_ALLOWED_HOSTS=" other.example.com , jira.EXAMPLE.com " FAKECURL_BODY="$SEARCH" run "$S/jira-mine.sh"
assert_eq "$CODE" "0" "exit"
assert_eq "$(jq -r '.[-1]' <<<"$(argv 1)")" "https://JIRA.example.com:8443/rest/api/2/search/jql" "url"
http_sandbox 'JIRA_BASE_URL=https://jira.example.com'
ASDLC_JIRA_ALLOWED_HOSTS=other.example.com run "$S/jira-mine.sh"
assert_eq "$CODE" "1" "exit"; assert_eq "$(calls)" "0" "curl calls"

t "allowing a host does not relax the URL shape"
http_sandbox 'JIRA_BASE_URL=http://jira.example.com'
ASDLC_JIRA_ALLOWED_HOSTS=jira.example.com run "$S/jira-mine.sh"
assert_eq "$CODE" "1" "exit"; assert_eq "$(calls)" "0" "curl calls"

t "ASDLC_JIRA_ALLOWED_HOSTS in the repo config has no effect"
http_sandbox 'JIRA_BASE_URL=https://jira.example.com' 'ASDLC_JIRA_ALLOWED_HOSTS=jira.example.com'
run "$S/jira-mine.sh"
assert_eq "$CODE" "1" "exit"
assert_contains "$ERR" "unknown key 'ASDLC_JIRA_ALLOWED_HOSTS' ignored" "parser warning"
assert_contains "$ERR" "'jira.example.com'" "refusal"
assert_eq "$(calls)" "0" "curl calls"

t "atlassian.net hosts need no opt-in; trailing slashes and host case are normalised"
http_sandbox 'JIRA_BASE_URL=https://Example.atlassian.net//'
FAKECURL_BODY="$SEARCH" run "$S/jira-mine.sh"
assert_eq "$CODE" "0" "exit"
assert_eq "$(jq -r '.[-1]' <<<"$(argv 1)")" "https://Example.atlassian.net/rest/api/2/search/jql" "url"

# --- (c) Jira request shape ---------------------------------------------------
t "Jira GET: --user email:token, -G, URL last and right after --"
http_sandbox
FAKECURL_BODY="$SEARCH" run "$S/jira-mine.sh"
a="$(argv 1)"
assert_eq "$CODE" "0" "exit"; assert_eq "$(calls)" "1" "curl calls"
assert_eq "$(after --user "$a")" "me@example.com:s3cr3t-value" "--user"
assert_arg -G "$a"; assert_no_arg -X "$a"
assert_eq "$(jq -r '.[-1]' <<<"$a")" "https://example.atlassian.net/rest/api/2/search/jql" "URL last"
assert_eq "$(jq -r '.[-2]' <<<"$a")" "--" "-- before the URL"
assert_eq "$(jq -r '[.[] | select(. == "--")] | length' <<<"$a")" "1" "one --"
assert_contains "$(after --data-urlencode "$a")" "jql=" "caller args kept before --"

t "Jira POST: -X POST and no -G, still ending in -- URL"
http_sandbox
FAKECURL_BODY='{"transitions":[{"id":"21","name":"Start work","to":{"name":"In Progress"}}]}' \
  run "$S/jira-transition.sh" PROJ-1 "In Progress"
assert_eq "$CODE" "0" "exit"; assert_eq "$(calls)" "3" "curl calls (status, transitions, POST)"
st="$(argv 1)"; g="$(argv 2)"; p="$(argv 3)"
assert_eq "$(jq -r '.[-1]' <<<"$st")" "https://example.atlassian.net/rest/api/3/issue/PROJ-1" "status GET URL"
assert_arg "fields=status" "$st"; assert_arg -G "$st"
assert_arg -G "$g"; assert_no_arg -X "$g"
assert_eq "$(after -X "$p")" "POST" "-X"; assert_no_arg -G "$p"
assert_eq "$(after --user "$p")" "me@example.com:s3cr3t-value" "--user"
assert_eq "$(jq -r '.[-1]' <<<"$p")" "https://example.atlassian.net/rest/api/3/issue/PROJ-1/transitions" "URL last"
assert_eq "$(jq -r '.[-2]' <<<"$p")" "--" "-- before the URL"
assert_eq "$(jq -c . <<<"$(after -d "$p")")" '{"transition":{"id":"21"}}' "body"

# --- (d) Bitbucket auth -------------------------------------------------------
t "BB_AUTH=bearer (the default): Authorization header, no --user"
http_sandbox
run "$S/bb-pr-comment.sh" 7 "hi"
a="$(argv 1)"
assert_eq "$CODE" "0" "exit"; assert_eq "$(calls)" "1" "curl calls"
assert_eq "$(jq -r 'index("Authorization: Bearer bb-s3cr3t-value") as $i | .[$i - 1]' <<<"$a")" "-H" "-H before the header"
assert_no_arg --user "$a"

t "BB_AUTH=basic with BITBUCKET_EMAIL: --user email:token, no Bearer header"
http_sandbox 'BB_AUTH=basic'
BITBUCKET_EMAIL=bb@example.com run "$S/bb-pr-comment.sh" 7 "hi"
a="$(argv 1)"
assert_eq "$CODE" "0" "exit"
assert_eq "$(after --user "$a")" "bb@example.com:bb-s3cr3t-value" "--user"
assert_no_arg "Authorization: Bearer bb-s3cr3t-value" "$a"

t "BB_AUTH=basic without BITBUCKET_EMAIL fails before any request"
http_sandbox 'BB_AUTH=basic'
run "$S/bb-pr-comment.sh" 7 "hi"
assert_eq "$CODE" "1" "exit"; assert_contains "$ERR" "BITBUCKET_EMAIL" "reason"
assert_eq "$(calls)" "0" "curl calls"

# --- (e) Bitbucket URL and slugs -----------------------------------------------
t "Bitbucket URL is api.bitbucket.org/2.0/repositories/<workspace>/<repo>/..."
http_sandbox
run "$S/bb-pr-comment.sh" 7 "hi"
a="$(argv 1)"
assert_eq "$(jq -r '.[-1]' <<<"$a")" "https://api.bitbucket.org/2.0/repositories/acme/widgets/pullrequests/7/comments" "comment URL"
assert_eq "$(jq -r '.[-2]' <<<"$a")" "--" "-- before the URL"
assert_eq "$(after -X "$a")" "POST" "-X"
: > "$FAKECURL_LOG"
FAKECURL_BODY='{"id":7,"links":{"html":{"href":"https://bitbucket.org/acme/widgets/pull-requests/7"}}}' \
  run "$S/bb-open-pr.sh" feature/x "Add x"
assert_eq "$CODE" "0" "exit"; assert_eq "$OUT" "7 https://bitbucket.org/acme/widgets/pull-requests/7" "output"
assert_eq "$(jq -r '.[-1]' <<<"$(argv 1)")" "https://api.bitbucket.org/2.0/repositories/acme/widgets/pullrequests" "PR URL"

for pair in 'BB_REPO=../x' 'BB_REPO=..' 'BB_REPO=.' 'BB_REPO=a/b' 'BB_REPO=-x' 'BB_WORKSPACE=-x' 'BB_WORKSPACE=a b' 'BB_WORKSPACE=a?b'; do
  t "refused before any request: $pair"
  http_sandbox "$pair"
  run "$S/bb-pr-comment.sh" 7 "hi"
  assert_eq "$CODE" "1" "exit"
  assert_contains "$ERR" "${pair%%=*}" "reason"
  assert_eq "$(calls)" "0" "curl calls"
done

t "setup check: bad Bitbucket slugs are a FAIL line, no request"
http_sandbox 'BB_REPO=../x'
run "$S/jira-setup.sh" check
assert_eq "$CODE" "1" "exit"; assert_contains "$OUT" "FAIL  BB_REPO '../x' is refused" "FAIL line"
assert_eq "$(calls)" "0" "curl calls"

# --- (f) failure messages -----------------------------------------------------
t "unreachable host: Could not reach, non-zero"
http_sandbox
FAKECURL_EXIT=7 FAKECURL_CODE=000 run "$S/jira-mine.sh"
assert_eq "$CODE" "1" "exit"; assert_contains "$ERR" "Could not reach Jira" "message"
FAKECURL_EXIT=7 FAKECURL_CODE=000 run "$S/bb-pr-comment.sh" 7 "hi"
assert_eq "$CODE" "1" "bb exit"; assert_contains "$ERR" "Could not reach Bitbucket" "bb message"

t "HTTP 401: says so and hints at the credentials"
http_sandbox
FAKECURL_CODE=401 run "$S/jira-mine.sh"
assert_eq "$CODE" "1" "exit"
assert_contains "$ERR" "Jira returned HTTP 401" "message"
assert_contains "$ERR" "Auth failed. Check JIRA_EMAIL" "hint"

t "HTTP 503: says so"
http_sandbox
FAKECURL_CODE=503 run "$S/jira-mine.sh"
assert_eq "$CODE" "1" "exit"; assert_contains "$ERR" "HTTP 503" "message"
FAKECURL_CODE=503 run "$S/bb-pr-comment.sh" 7 "hi"
assert_eq "$CODE" "1" "bb exit"; assert_contains "$ERR" "Bitbucket returned HTTP 503" "bb message"

# --- (g) tokens stay out of everything a person sees ------------------------------
t "token values never reach stdout or stderr (they do reach curl's argv, which only the stub sees)"
http_sandbox
FAKECURL_CODE=401 run "$S/jira-setup.sh" check
assert_eq "$CODE" "1" "check exit"
assert_not_contains "$OUT$ERR" "s3cr3t-value" "Jira token in check output"
assert_not_contains "$OUT$ERR" "bb-s3cr3t-value" "Bitbucket token in check output"
assert_contains "$(cat "$FAKECURL_LOG")" "s3cr3t-value" "stub sees the token"
for code in 401 503; do
  FAKECURL_CODE=$code run "$S/jira-mine.sh"
  assert_not_contains "$OUT$ERR" "s3cr3t-value" "token in failing jira call ($code)"
  FAKECURL_CODE=$code run "$S/bb-pr-comment.sh" 7 "hi"
  assert_not_contains "$OUT$ERR" "s3cr3t-value" "token in failing bb call ($code)"
done
FAKECURL_EXIT=7 FAKECURL_CODE=000 run "$S/jira-mine.sh"
assert_not_contains "$OUT$ERR" "s3cr3t-value" "token when unreachable"
FAKECURL_BODY="$SEARCH" run "$S/jira-mine.sh"
assert_not_contains "$OUT$ERR" "s3cr3t-value" "token in a successful call"
http_sandbox 'JIRA_BASE_URL=https://evil.example.com'
run "$S/jira-mine.sh"
assert_not_contains "$OUT$ERR" "s3cr3t-value" "token when the URL is refused"

# --- (h) the argument builder and the download helper ---------------------------
# Ask the builder for its argv in a subshell and print it as a JSON array.
build() {  # <svc> <METHOD> <path> [extra...]
  ( . "$S/lib.sh"; BB_AUTH="${BB_AUTH:-bearer}"; JIRA_BASE_URL=https://example.atlassian.net
    asdlc_curl_args "$@"; printf '%s\n' "${ASDLC_CURL_ARGV[@]}" | jq -R . | jq -sc . )
}
t "asdlc_curl_args: per service and method, looked up by name"
export BITBUCKET_EMAIL=bb@example.com
a="$(build jira GET /rest/api/2/x /tmp/o --data-urlencode a=b)"
assert_eq "$(after -o "$a")" "/tmp/o" "-o"; assert_eq "$(after -w "$a")" '%{http_code}' "-w"
assert_eq "$(after --user "$a")" "me@example.com:s3cr3t-value" "jira --user"; assert_arg -G "$a"; assert_no_arg -X "$a"
assert_eq "$(after --data-urlencode "$a")" "a=b" "extra arg"
assert_eq "$(jq -r '.[-1]' <<<"$a")" "https://example.atlassian.net/rest/api/2/x" "jira URL"
assert_eq "$(jq -r '[.[] | select(startswith("Accept:"))] | .[0]' <<<"$a")" "Accept: application/json" "json Accept"
a="$(build jira POST /rest/api/2/x /tmp/o -d '{}')"
assert_eq "$(after -X "$a")" "POST" "jira -X"; assert_no_arg -G "$a"; assert_eq "$(after -d "$a")" "{}" "body"
a="$(build bb GET /repositories/a/b /tmp/o)"
assert_eq "$(jq -r '.[-1]' <<<"$a")" "https://api.bitbucket.org/2.0/repositories/a/b" "bb URL"
assert_arg "Authorization: Bearer bb-s3cr3t-value" "$a"; assert_no_arg --user "$a"
a="$(BB_AUTH=basic build bb POST /repositories/a/b /tmp/o)"
assert_eq "$(after --user "$a")" "bb@example.com:bb-s3cr3t-value" "bb basic --user"; assert_eq "$(after -X "$a")" "POST" "bb -X"
assert_eq "$(jq -r '.[-2]' <<<"$a")" "--" "-- before URL"

PNG_HEAD="$(printf '\211PNG\r\n\032\nX')"   # the trailing X keeps $(...) from eating the final newline byte
dl() { ( . "$S/lib.sh"; asdlc_conf_defaults; JIRA_BASE_URL=https://example.atlassian.net ASDLC_FIXTURES=""
         asdlc_download "$@" ); }   # <path> <dest> <max>; prints the verdict word
P=/rest/api/2/attachment/content/10001

t "asdlc_download: redirect-safe curl arguments, stored under the final name"
http_sandbox
FAKECURL_BODY="${PNG_HEAD}data" run dl $P "$SB/a/img.png" 1000
a="$(argv 1)"
assert_eq "$CODE" "0" "exit"; assert_eq "$OUT" "200" "verdict"; assert_file "$SB/a/img.png"
assert_arg -L "$a"; assert_eq "$(after --proto-redir "$a")" "=https" "--proto-redir"
assert_eq "$(after --proto "$a")" "=https" "--proto"; assert_eq "$(after --max-redirs "$a")" "3" "--max-redirs"
assert_eq "$(after --max-filesize "$a")" "1000" "--max-filesize"; assert_eq "$(after --max-time "$a")" "60" "--max-time"
assert_eq "$(jq -r '[.[] | select(startswith("Accept:"))] | .[0]' <<<"$a")" "Accept: */*" "Accept"
assert_no_arg --location-trusted "$a"
assert_eq "$(jq -r '.[-1]' <<<"$a")" "https://example.atlassian.net$P" "URL"
assert_eq "$(ls "$SB/a" | wc -l | tr -d ' ')" "1" "no temp file left"

t "asdlc_download: jpeg, gif and webp are accepted"
for body in "$(printf '\377\330\377\340xx')" "GIF89a-xx" "GIF87a-xx" "RIFFabcdWEBPxx"; do
  rm -f "$SB/a/i"; FAKECURL_BODY="$body" run dl $P "$SB/a/i" 1000
  assert_eq "$CODE" "0" "exit for ${body:0:6}"; assert_file "$SB/a/i"
done

t "asdlc_download: a non-image body (HTML, SVG, RIFF but not WebP) is rejected and not stored"
for body in '<html><body>Please log in</body></html>' '<svg xmlns="http://www.w3.org/2000/svg"/>' 'RIFFabcdWAVEfmt ' ''; do
  rm -f "$SB/a/n"; FAKECURL_BODY="$body" run dl $P "$SB/a/n" 1000
  assert_eq "$CODE" "1" "exit"; assert_eq "$OUT" "type" "verdict"
  [ ! -e "$SB/a/n" ] && ok || nok "stored a non-image"
done
assert_eq "$(ls "$SB/a" | tr '\n' ' ')" "i img.png " "no temp files left"

t "asdlc_download: an over-size body is rejected (by the byte check and by curl's own limit)"
rm -f "$SB/a/big"
FAKECURL_BODY="${PNG_HEAD}0123456789" run dl $P "$SB/a/big" 12
assert_eq "$CODE" "1" "exit"; assert_eq "$OUT" "size" "verdict"; [ ! -e "$SB/a/big" ] && ok || nok "stored an oversize body"
FAKECURL_EXIT=63 FAKECURL_CODE=000 FAKECURL_BODY="${PNG_HEAD}x" run dl $P "$SB/a/big" 1000
assert_eq "$OUT" "size" "curl 63 verdict"; [ ! -e "$SB/a/big" ] && ok || nok "stored after curl 63"

t "asdlc_download: HTTP errors report the code; only numeric attachment paths are allowed"
FAKECURL_CODE=404 FAKECURL_BODY="${PNG_HEAD}x" run dl $P "$SB/a/e" 1000
assert_eq "$CODE" "1" "exit"; assert_eq "$OUT" "404" "verdict"; [ ! -e "$SB/a/e" ] && ok || nok "stored a 404 body"
: > "$FAKECURL_LOG"
for bad in /rest/api/2/issue/PROJ-1 /rest/api/2/attachment/content/1x /rest/api/2/attachment/content/1/../2 /rest/api/2/attachment/content/; do
  run dl "$bad" "$SB/a/e" 1000; assert_eq "$CODE" "1" "refused $bad"
done
run dl $P "$SB/a/e" 10x; assert_eq "$CODE" "1" "refused non-numeric limit"
assert_eq "$(calls)" "0" "curl calls for refused requests"

t "asdlc_download: fixtures serve the bytes like asdlc_http"
sandbox; use_fixtures basic; mkdir -p fx/jira/rest/api/2/attachment/content
printf '\211PNG\r\n\032\n\000\001' > fx/jira/rest/api/2/attachment/content/10001.json
( . "$S/lib.sh"; asdlc_conf_defaults; JIRA_BASE_URL=https://example.atlassian.net; ASDLC_FIXTURES="$SB/fx"
  asdlc_download $P "$SB/o/img.png" 1000 >"$SB/verdict" )
assert_eq "$(cat "$SB/verdict")" "200" "verdict"; assert_eq "$(wc -c < "$SB/o/img.png" | tr -d ' ')" "10" "bytes kept intact"
assert_eq "$(requests | jq -r '.[0].path')" "$P" "logged"

t "tokens stay out of stdout and stderr in the download path"
http_sandbox
for code in 200 401 503; do
  FAKECURL_CODE=$code FAKECURL_BODY="${PNG_HEAD}x" run dl $P "$SB/a/t$code" 1000
  assert_not_contains "$OUT$ERR" "s3cr3t-value" "token in download ($code)"
done

finish
