#!/usr/bin/env bash
# The review queue: this plugin's own PRs that still wait for a human review. Read-only (GETs and
# git ls-remote only); prints no PR titles or ticket text.
# Usage: review-queue.sh [--plans-dir plans] [--all]
#   Counts every <plans-dir>/*.plan.md whose `pr` is https://bitbucket.org/<BB_WORKSPACE>/<BB_REPO>/pull-requests/<id>
#   (D-H1: PRs this plugin opened, not every PR the user authored). Any other host is skipped with a warning.
# Output:
#   QUEUE <waiting>/<max>
#   PR <id> <KEY> <state> human=<none|current|stale> teammate=<yes|no> tier=<high|normal|skim|unknown> reasons=<csv or ->
#   Only waiting PRs get a PR line; --all prints every PR (merged and declined too).
# Waiting = state OPEN or UNKNOWN, and human is not current, and teammate=no (D-H3).
# Exit: 0 under the cap (or REVIEW_QUEUE_MAX=0, which never caps), 18 at or over it, 2 on a config error
#   (REVIEW_QUEUE_MAX not a whole number, BB_WORKSPACE/BB_REPO unset or refused). A bad cap fails closed:
#   it is refused rather than guessed.
# Where each fact comes from:
#   REST (when BITBUCKET_TOKEN is set, or under --fixtures), GET /repositories/{ws}/{repo}/pullrequests/{id}:
#     .state (OPEN|MERGED|DECLINED|SUPERSEDED), .source.commit.hash (a SHORT hash), .author.account_id,
#     .participants[].approved and .participants[].user.account_id. teammate=yes when a participant whose
#     account_id differs from the author's has approved=true; no author account_id means teammate=no.
#   REST, GET .../pullrequests/{id}/comments?sort=-created_on&pagelen=50: .values[].content.raw, .created_on,
#     .deleted, and .next (followed only when it is under https://api.bitbucket.org/2.0/, at most 5 pages).
#     The remote record is the comment with the greatest created_on whose first line
#     review-record.sh parse-comment accepts, so it does not matter whether the API sorts as asked.
#     Not read: .source.branch.name (the branch comes from the plan's own `branch` field).
#   git (always tried first), one `git ls-remote --heads origin` per run: a missing branch means CLOSED
#     (PRs are opened with close_source_branch), and a CLOSED PR gets no REST call unless --all asks for
#     its exact state, so merged plans cost nothing. Otherwise the branch's sha is the head and, with no
#     REST answer, the state is OPEN. The local record is `review-record.sh last <KEY> <id>` (always under ./plans/).
#   REST and git agree on state only through REST: REST's state wins when it answered.
# Combining: a record counts when its sha equals the head or starts with it (REST's hash is short).
#   REST and git heads that do not match mean human=stale. If neither can tell the state it is UNKNOWN
#   (waiting, with the reason on stderr). The risk tier comes from review-report.sh must-read
#   <plans-dir>/pr-review-<KEY>.md (pr-review-<KEY>-s<k>.md for a plan on slice k > 1) --diff origin/<TARGET_BRANCH> <head>; no report means tier=unknown, and
#   a skim claim that cannot be checked becomes normal.
# The Bitbucket shapes above are the documented ones, not verified live.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
ASDLC_CONF_OPTIONAL=1 asdlc_init "$@"; set -- ${ASDLC_ARGS[@]+"${ASDLC_ARGS[@]}"}

die2() { echo "review-queue: $*" >&2; exit 2; }
PLANS="plans"; ALL=0
while [ $# -gt 0 ]; do
  case "$1" in
    --plans-dir) [ $# -ge 2 ] || die2 "--plans-dir needs a directory"; PLANS="$2"; shift 2 ;;
    --all) ALL=1; shift ;;
    *) die2 "usage: review-queue.sh [--plans-dir plans] [--all]" ;;
  esac
done
case "$PLANS" in ''|-*) die2 "--plans-dir '$(printf '%s' "$PLANS" | tr -cd '[:print:]')' is refused" ;; esac

[[ $REVIEW_QUEUE_MAX =~ ^[0-9]{1,9}$ ]] ||
  die2 "REVIEW_QUEUE_MAX '$(printf '%s' "$REVIEW_QUEUE_MAX" | tr -cd '[:print:]')' in $ASDLC_CONF_FILE must be a whole number (0 = no cap)"
MAX=$((10#$REVIEW_QUEUE_MAX))
[ -n "$BB_WORKSPACE" ] && [ -n "$BB_REPO" ] || die2 "BB_WORKSPACE and BB_REPO must be set in $ASDLC_CONF_FILE"
bb_err="$(asdlc_check_bb_target 2>&1)" || die2 "$bb_err"

RR="$ASDLC_JIRA_SCRIPTS/review-record.sh"
RP="$ASDLC_SHARED_SCRIPTS/review-report.sh"
PS="$ASDLC_SHARED_SCRIPTS/plan-state.sh"
API="https://api.bitbucket.org/2.0"
SHA_RE='^[0-9a-f]{7,40}$'
URL_PREFIX="https://bitbucket.org/$BB_WORKSPACE/$BB_REPO/pull-requests/"

REST=0
if [ -n "$ASDLC_FIXTURES" ]; then REST=1
elif [ -n "${BITBUCKET_TOKEN:-}" ] && { [ "$BB_AUTH" != basic ] || [ -n "${BITBUCKET_EMAIL:-}" ]; }; then REST=1; fi

printable() { printf '%s' "$1" | tr -cd '[:print:]'; }
log_warn() { asdlc_warn "review-queue: $*"; }

# rest_pr <id>: sets R_STATE R_HEAD R_TEAM R_REC (any may be empty). Returns 1 when the PR itself can't be read.
R_STATE=""; R_HEAD=""; R_TEAM=""; R_REC=""
rest_pr() {
  local id="$1" err pr line st hd tm path page=0 body nx ts raw sha best_t="" tail_
  R_STATE=""; R_HEAD=""; R_TEAM=""; R_REC=""
  err="$(mktemp)"
  if ! pr="$(asdlc_get_json bb "/repositories/$BB_WORKSPACE/$BB_REPO/pullrequests/$id" 2>"$err")"; then
    log_warn "PR $id: Bitbucket REST failed: $(printable "$(head -n1 "$err")")"; rm -f "$err"; return 1
  fi
  line="$(jq -r '[ (.state // ""), (.source.commit.hash // ""),
        ((.author.account_id // "") as $a |
         if $a == "" then "no"
         elif ([.participants[]? | select(.approved == true and ((.user.account_id // "") != "") and .user.account_id != $a)] | length) > 0
         then "yes" else "no" end) ] | join("|")' <<<"$pr" 2>/dev/null)" || line=""
  IFS='|' read -r st hd tm <<<"$line" || true
  case "$st" in OPEN|MERGED|DECLINED|SUPERSEDED) ;; *) log_warn "PR $id: unexpected Bitbucket response (state)"; rm -f "$err"; return 1 ;; esac
  [[ $hd =~ $SHA_RE ]] || hd=""
  R_STATE="$st"; R_HEAD="$hd"; R_TEAM="${tm:-no}"

  path="/repositories/$BB_WORKSPACE/$BB_REPO/pullrequests/$id/comments?sort=-created_on&pagelen=50"
  while [ -n "$path" ] && [ "$page" -lt 5 ]; do
    page=$((page + 1))
    if ! body="$(asdlc_get_json bb "$path" 2>"$err")"; then
      log_warn "PR $id: comments not read (a human-review comment may be missed): $(printable "$(head -n1 "$err")")"; break
    fi
    while IFS=' ' read -r ts raw; do
      [ -n "$ts" ] || continue
      if sha="$(printf '%s' "$raw" | "$RR" parse-comment 2>/dev/null)"; then
        if [ -z "$best_t" ] || [[ $ts > $best_t ]]; then best_t="$ts"; R_REC="$sha"; fi
      fi
    done < <(jq -r --arg p "$ASDLC_HR_PREFIX" '.values[]? | select(.deleted != true)
              | (.content.raw // "") as $r | select($r | startswith($p))
              | [((.created_on // "0") | gsub(" "; "")), ($r | split("\n")[0])] | join(" ")' <<<"$body" 2>/dev/null)
    nx="$(jq -r '.next // empty' <<<"$body" 2>/dev/null)" || nx=""
    path=""
    if [ -n "$nx" ]; then
      case "$nx" in
        "$API/repositories/$BB_WORKSPACE/$BB_REPO/pullrequests/$id/comments?"*)
          tail_="${nx#"$API"}"
          if [[ $tail_ =~ ^[A-Za-z0-9._~:/?\&=%+,-]+$ ]]; then path="$tail_"; else log_warn "PR $id: odd 'next' link ignored"; fi ;;
        *) log_warn "PR $id: 'next' link is not under the Bitbucket API; not followed" ;;
      esac
      if [ -n "$path" ] && [ "$page" -ge 5 ]; then log_warn "PR $id: more than 5 pages of comments; the rest are not read"; fi
    fi
  done
  rm -f "$err"
  return 0
}

# One ls-remote per run lists every branch on origin (no per-plan network call).
GIT_HEADS=""; GIT_HEADS_OK=""
git_heads() {
  [ -z "$GIT_HEADS_OK" ] || return 0
  if GIT_HEADS="$(GIT_TERMINAL_PROMPT=0 git ls-remote --heads origin 2>/dev/null)"; then GIT_HEADS_OK=1
  else GIT_HEADS=""; GIT_HEADS_OK=0; fi
}
# git_pr <branch>: sets G_STATE (OPEN|CLOSED|"") and G_HEAD (sha40 or "").
G_STATE=""; G_HEAD=""
git_pr() {
  local b="$1" sha ref
  G_STATE=""; G_HEAD=""
  case "$b" in ''|-*) return 1 ;; esac
  git check-ref-format "refs/heads/$b" >/dev/null 2>&1 || return 1
  git_heads; [ "$GIT_HEADS_OK" = 1 ] || return 1
  while read -r sha ref; do
    if [ "$ref" = "refs/heads/$b" ] && [[ $sha =~ ^[0-9a-f]{40}$ ]]; then G_HEAD="$sha"; fi
  done <<<"$GIT_HEADS"
  if [ -n "$G_HEAD" ]; then G_STATE="OPEN"; else G_STATE="CLOSED"; fi
  return 0
}

prefix_match() {  # <record sha> <head: full or short>
  [ -n "$2" ] && [ "${#2}" -ge 7 ] && [ "${1#"$2"}" != "$1" ] || [ "$1" = "$2" ]
}

# tier_of <KEY> <branch> [<report id>] -> T_TIER, T_REASONS. The report id is <KEY>, or <KEY>-s<k> for the
# plan's slice k > 1 (jira-run passes that as review-pr --id), so a slice PR reads its own report.
T_TIER=""; T_REASONS=""
tier_of() {
  local key="$1" b="$2" rep="$PLANS/pr-review-${3:-$1}.md" out ref="" args
  T_TIER="unknown"; T_REASONS="-"
  [ -f "$rep" ] || return 0
  args=(must-read "$rep")
  if [ -n "$TARGET_BRANCH" ] && [ -n "$b" ]; then
    case "$b" in -*) ;; *)
      if git rev-parse --verify --quiet --end-of-options "origin/$b^{commit}" >/dev/null 2>&1; then ref="origin/$b"
      else ref="$b"; fi ;;
    esac
  fi
  [ -z "$ref" ] || args+=(--diff "origin/$TARGET_BRANCH" "$ref")
  out="$("$RP" "${args[@]}" 2>/dev/null)" || true
  T_TIER="$(jq -r '.tier // "high"' <<<"$out" 2>/dev/null)" || T_TIER="high"
  case "$T_TIER" in high|normal|skim) ;; *) T_TIER="high" ;; esac
  T_REASONS="$(jq -r '(.reasons // []) | map(select(test("^[a-z-]+$"))) | join(",")' <<<"$out" 2>/dev/null)" || T_REASONS=""
  [ -n "$T_REASONS" ] || T_REASONS="-"
  # A skim claim nobody checked against the diff is a normal PR.
  if [ "$T_TIER" = skim ] && [ -z "$ref" ]; then T_TIER="normal"; fi
  return 0
}

[ "$REST" -eq 1 ] || log_warn "no Bitbucket token: using git only (a PR whose branch still exists counts as open)"

waiting=0; lines=""
for plan in "$PLANS"/*.plan.md; do
  [ -f "$plan" ] || continue
  url="$("$PS" get "$plan" pr 2>/dev/null || true)"; url="$(asdlc_trim "$url")"
  [ -n "$url" ] || continue
  key="$("$PS" get "$plan" ticket 2>/dev/null || true)"; key="$(asdlc_trim "$key")"
  [ -n "$key" ] || { key="${plan##*/}"; key="${key%.plan.md}"; }
  if ! asdlc_is_key "$key"; then log_warn "$(printable "$plan"): not a ticket key; skipped"; continue; fi
  id="${url#"$URL_PREFIX"}"; id="${id%/}"
  if [ "$id" = "$url" ] || ! [[ $id =~ ^[0-9]{1,9}$ ]]; then
    log_warn "$key: pr '$(printable "$url")' is not a pull request of $BB_WORKSPACE/$BB_REPO on bitbucket.org; skipped"; continue
  fi
  id=$((10#$id))
  branch="$("$PS" get "$plan" branch 2>/dev/null || true)"; branch="$(asdlc_trim "$branch")"

  git_ok=0; git_pr "$branch" && git_ok=1 || { G_STATE=""; G_HEAD=""; }
  # A branch gone from origin is a closed PR: skip REST for it unless --all wants its exact state.
  rest_ok=0
  if [ "$REST" -eq 1 ] && { [ "$git_ok" -eq 0 ] || [ "$G_STATE" != CLOSED ] || [ "$ALL" -eq 1 ]; } && rest_pr "$id"; then
    rest_ok=1
  else R_STATE=""; R_HEAD=""; R_TEAM=""; R_REC=""; fi
  local_rec=""
  if [ -d "plans/$key" ] || [ -L plans ]; then local_rec="$("$RR" last "$key" "$id" 2>/dev/null || true)"; fi

  state="UNKNOWN"
  if [ "$rest_ok" -eq 1 ]; then state="$R_STATE"
  elif [ "$git_ok" -eq 1 ]; then state="$G_STATE"
  else log_warn "$key PR $id: neither Bitbucket nor git could tell its state; counted as waiting"; fi
  teammate="no"; [ "$rest_ok" -eq 1 ] && [ "$R_TEAM" = yes ] && teammate="yes"

  # The head to compare records with: git's full sha, else REST's (short) hash. Different heads: stale.
  head=""; disagree=0
  if [ -n "$G_HEAD" ]; then head="$G_HEAD"; elif [ -n "$R_HEAD" ]; then head="$R_HEAD"; fi
  if [ -n "$G_HEAD" ] && [ -n "$R_HEAD" ] && ! prefix_match "$G_HEAD" "$R_HEAD"; then disagree=1; fi
  human="none"
  if [ "$disagree" -eq 1 ]; then human="stale"
  elif [ -n "$R_REC" ] || [ -n "$local_rec" ]; then
    human="stale"
    if [ -n "$head" ]; then
      if [ -n "$R_REC" ] && prefix_match "$R_REC" "$head"; then human="current"; fi
      if [ -n "$local_rec" ] && prefix_match "$local_rec" "$head"; then human="current"; fi
    fi
  fi

  is_waiting=0
  case "$state" in OPEN|UNKNOWN) [ "$human" != current ] && [ "$teammate" = no ] && is_waiting=1 ;; esac
  [ "$is_waiting" -eq 0 ] || waiting=$((waiting + 1))
  if [ "$is_waiting" -eq 1 ] || [ "$ALL" -eq 1 ]; then
    sl="$("$PS" get "$plan" slice 2>/dev/null || true)"; sl="$(asdlc_trim "$sl")"
    rid="$key"; if [[ $sl =~ ^[1-9][0-9]{0,2}$ ]] && [ "$sl" -gt 1 ]; then rid="$key-s$sl"; fi
    tier_of "$key" "$branch" "$rid"
    lines="$lines$(printf 'PR %s %s %s human=%s teammate=%s tier=%s reasons=%s' "$id" "$key" "$state" "$human" "$teammate" "$T_TIER" "$T_REASONS")
"
  fi
done

echo "QUEUE $waiting/$MAX"
printf '%s' "$lines"
if [ "$MAX" -gt 0 ] && [ "$waiting" -ge "$MAX" ]; then exit 18; fi
exit 0
