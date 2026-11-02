#!/usr/bin/env bash
# Run lock, crash recovery and branch setup for /asdlc:jira-run. Run from the repo root;
# plans and the lock live in ./plans.
# Usage:
#   run-state.sh lock                          # take the run lock; prints the run id
#   run-state.sh unlock <run-id>               # release it (only the run that took it)
#   run-state.sh status                        # who holds the lock, since when
#   run-state.sh force-unlock                  # HUMAN ONLY: remove a crashed run's lock
#   run-state.sh reset-executing               # every plan left executing -> approved, if unchanged
#   run-state.sh list                          # every plan: id, state, branch, pr
#   run-state.sh start-branch <plan> <summary> # create, or resume, the plan's feature branch
#   run-state.sh next-slice <plan>             # a WAITING plan whose slice PR is merged -> the next slice
#
# force-unlock is deliberately not a prefix of any other subcommand, so a permission rule
# like "run-state.sh unlock:*" can never pre-approve it.
#
# start-branch prints the branch name on stdout. A plan whose header has no branch gets a new
# feature/<KEY>-<slug> off an up-to-date TARGET_BRANCH. A plan that recorded a branch in an
# earlier, crashed run resumes on that branch. An existing branch the plan didn't record is
# never reused or reset. From slice 2 on the name ends -s<k>: feature/<KEY>-<slug>-s<k>.
#
# next-slice (item 7, D-H9: a plan can be split into up to 3 sequential PR slices) moves a plan that
# is `waiting` (a slice's PR is open and later slices remain) back to `approved` for the next slice. It
# is the second of the only two scripted paths back to approved, the other being plan-state.sh
# reset-executing; both go through restore_approved in plan-lib.sh, a compare-and-set on the hash the
# human approved, so no approval is created here. It acts only when ALL hold, else the plan is untouched:
#   - the status is `waiting` and the approved part still hashes to the stored plan_hash (else exit 11);
#   - a later slice exists (else exit 2);
#   - Bitbucket REST (GET .../pullrequests/<id>) says the recorded PR is MERGED. Nothing else counts:
#     no token, a failed call, OPEN, DECLINED, SUPERSEDED, or a PR that is not this repo's all exit 19.
#     A merge is never inferred from git.
# Then, in one write: it appends `- slice <k>: <pr url> merged` under Progress, sets slice to k+1,
# clears branch and pr, and sets status approved. start-branch then cuts a new branch from the target.
#
# Exit codes: 0 ok; 2 bad input or refused; 10 the lock is held; 11 reset-executing refused
# some plan (its approved part changed); 12 the working tree has uncommitted changes;
# 13 the branch exists but this plan didn't record it; 14 the plan's recorded branch is gone;
# 15 the plan has logged progress but records no branch (the branch is gone or was cleared).
# next-slice: 0 moved to the next slice; 2 refused (not waiting, no later slice, bad config);
# 11 the approved part changed (re-stamp, re-approve); 16 no header block; 19 the merge is not confirmed.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
ASDLC_CONF_OPTIONAL=1 asdlc_init "$@"; set -- ${ASDLC_ARGS[@]+"${ASDLC_ARGS[@]}"}
PS="$ASDLC_SHARED_SCRIPTS/plan-state.sh"
PLANS="./plans"
LOCK="$PLANS/.jira-run.lock"

die() { echo "$2" >&2; exit "$1"; }
plan_id() { local i; i="$("$PS" get "$1" ticket 2>/dev/null || true)"; echo "${i:-$(basename "$1" .plan.md)}"; }
now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
owner_field() { [ -f "$LOCK/owner" ] && awk -v k="$1:" '$1==k {sub(/^[^:]*:[ \t]*/,""); print; exit}' "$LOCK/owner"; return 0; }

lock_holder() {  # one line describing the current holder
  local id started host age=""
  id="$(owner_field run_id)"; started="$(owner_field started)"; host="$(owner_field host)"
  if [ -z "$id" ]; then echo "held, with no owner record (an older version, or a crash while locking)"; return; fi
  local s; s="$(owner_field started_epoch)"
  if [ -n "$s" ]; then age=" ($(( ($(date +%s) - s) / 60 )) min ago)"; fi
  echo "held by run $id since $started$age on $host"
}

# A branch name from config or a plan header: no leading '-' (git would read an option),
# and valid branch syntax.
check_branch_name() {  # <what> <name>
  case "$2" in ''|-*) die 2 "$1 '$(printf '%s' "$2" | tr -cd '[:print:]')' is not a usable branch name" ;; esac
  git check-ref-format --branch "$2" >/dev/null 2>&1 \
    || die 2 "$1 '$(printf '%s' "$2" | tr -cd '[:print:]')' is not a valid branch name"
}

# The summary comes from the ticket: keep [a-z0-9-] only, so it can't add options or paths.
slugify() {
  local s
  s="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | LC_ALL=C sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' | cut -c1-40)"
  s="${s%-}"
  printf '%s' "${s:-work}"
}

# An MCP capture request (plans/<KEY>/.mcp/, plans/.mcp/search/, plans/.mcp/bb/) left by a crashed run
# is dead after its expires_epoch. Each kind is swept by its own request, never by a neighbour's; a
# directory with no readable request goes after 10 minutes. Best effort, never fatal, and never
# through a symbolic link (plans, plans/<KEY>, .mcp or the kind's directory).
sweep_one() {  # <dir>: remove it if its request.json expired (or it has none and is 10 minutes old)
  local d="$1" f="$1/request.json" exp="" now; now="$(date +%s)"
  if [ -L "$d" ] || [ ! -d "$d" ]; then return 0; fi
  if [ -f "$f" ] && [ ! -L "$f" ]; then exp="$(jq -r '.expires_epoch // empty | tostring' "$f" 2>/dev/null || true)"; fi
  if [[ $exp =~ ^[0-9]+$ ]]; then
    if [ "$exp" -le "$now" ]; then rm -rf "$d" || true; fi
  elif [ -n "$(find "$d" -maxdepth 0 -mmin +10 2>/dev/null || true)" ]; then
    rm -rf "$d" || true
  fi
  return 0
}
sweep_mcp() {
  local d k
  if [ -L "$PLANS" ]; then return 0; fi
  for d in "$PLANS"/*/.mcp; do
    if [ -L "${d%/.mcp}" ]; then continue; fi
    sweep_one "$d"
  done
  d="$PLANS/.mcp"
  if [ ! -L "$d" ] && [ -d "$d" ]; then
    for k in search bb; do sweep_one "$d/$k"; done
    rmdir "$d" 2>/dev/null || true       # only when nothing live is left in it
  fi
  return 0
}

cmd="${1:?usage: run-state.sh <lock|unlock|status|force-unlock|reset-executing|list|start-branch|next-slice> ...}"
case "$cmd" in
  lock)
    mkdir -p "$PLANS"
    if ! mkdir "$LOCK" 2>/dev/null; then
      die 10 "another /asdlc:jira-run holds the lock: $(lock_holder). If that run crashed, a human can clear it with: run-state.sh force-unlock"
    fi
    id="$(date -u +%Y%m%dT%H%M%SZ)-$$-$RANDOM"
    { echo "run_id: $id"; echo "started: $(now_iso)"; echo "started_epoch: $(date +%s)"
      echo "host: $(hostname 2>/dev/null || echo unknown)"; } > "$LOCK/owner"
    sweep_mcp
    echo "$id"
    ;;
  unlock)
    id="${2:?usage: run-state.sh unlock <run-id>}"
    if [ ! -d "$LOCK" ]; then sweep_mcp; echo "not locked"; exit 0; fi
    held="$(owner_field run_id)"
    [ "$held" = "$id" ] || die 2 "refusing: the lock is $(lock_holder), not by run $id"
    rm -f "$LOCK/owner"; rmdir "$LOCK"
    sweep_mcp
    echo "unlocked (run $id)"
    ;;
  status)
    if [ -d "$LOCK" ]; then echo "locked: $(lock_holder)"; exit 10; fi
    echo "unlocked"
    ;;
  force-unlock)
    if [ ! -d "$LOCK" ]; then echo "not locked"; exit 0; fi
    echo "removing a lock $(lock_holder)"
    rm -f "$LOCK/owner"; rmdir "$LOCK" 2>/dev/null || die 2 "could not remove $LOCK (unexpected files inside?)"
    echo "unlocked"
    ;;
  reset-executing)
    refused=0; n=0
    for p in "$PLANS"/*.plan.md; do
      [ -e "$p" ] || continue
      st="$("$PS" check "$p" 2>/dev/null || true)"
      if [ "$st" = "EDITED" ] && [ "$("$PS" get "$p" status 2>/dev/null || true)" = "executing" ]; then
        n=$((n + 1)); refused=$((refused + 1))
        echo "$(plan_id "$p"): executing but EDITED — delete the extra progress line or fix the plan, then re-approve"
        continue
      fi
      [ "$st" = "EXECUTING" ] || continue
      n=$((n + 1)); id="$(plan_id "$p")"
      rc=0; "$PS" reset-executing "$p" >/dev/null 2>&1 || rc=$?
      case "$rc" in
        0)  echo "reset $id: executing -> approved" ;;
        11) echo "$id: its approved part changed during the crashed run — re-stamp and have a human re-approve"; refused=$((refused + 1)) ;;
        *)  echo "$id: reset-executing failed (exit $rc)"; refused=$((refused + 1)) ;;
      esac
    done
    [ "$n" -gt 0 ] || echo "no plan is executing"
    [ "$refused" -eq 0 ] || exit 11
    ;;
  list)
    dash() { if [ -n "$1" ]; then printf '%s' "$1"; else printf -- '-'; fi; }
    { printf 'PLAN\tSTATE\tBRANCH\tPR\n'
      for p in "$PLANS"/*.plan.md; do
        [ -e "$p" ] || continue
        st="$("$PS" check "$p" 2>/dev/null || true)"
        if [ "$st" = "EDITED" ] && [ "$("$PS" get "$p" status 2>/dev/null || true)" = "executing" ]; then st="EDITED (executing)"; fi
        printf '%s\t%s\t%s\t%s\n' "$(plan_id "$p")" "$st" \
          "$(dash "$("$PS" get "$p" branch 2>/dev/null || true)")" "$(dash "$("$PS" get "$p" pr 2>/dev/null || true)")"
      done; } | { command -v column >/dev/null && column -t -s "$(printf '\t')" || cat; }
    ;;
  start-branch)
    plan="${2:?usage: run-state.sh start-branch <plan> <summary>}"; summary="${3-}"
    [ "$("$PS" check "$plan" 2>/dev/null || true)" = "RUNNABLE" ] \
      || die 2 "refusing: $plan is not RUNNABLE ($("$PS" check "$plan" 2>/dev/null || true))"
    key="$("$PS" get "$plan" ticket)"
    recorded="$("$PS" get "$plan" branch)"
    slice="$("$PS" get "$plan" slice)"; slice="${slice:-1}"
    [[ $slice =~ ^[1-9][0-9]{0,2}$ ]] || die 2 "refusing: the plan's slice '$(printf '%s' "$slice" | tr -cd '[:print:]')' is not a whole number"
    sfx=""; if [ "$slice" -gt 1 ]; then sfx="-s$slice"; fi
    dirty="$(git status --porcelain --untracked-files=no)"
    current="$(git symbolic-ref --short -q HEAD || true)"

    if [ -n "$recorded" ]; then
      # Resume: an earlier run of this plan created the branch, then crashed.
      check_branch_name "recorded branch" "$recorded"
      # The plan file is editable, so a recorded branch is never trusted blindly: it must be
      # this ticket's own feature branch, and never the target branch.
      case "$recorded" in "feature/$key-"*) ;; *) die 2 "refusing: recorded branch '$recorded' is not a feature/$key-* branch" ;; esac
      [ "$recorded" != "$TARGET_BRANCH" ] || die 2 "refusing: recorded branch '$recorded' is the target branch"
      case "$recorded" in *"$sfx") ;; *) die 2 "refusing: recorded branch '$recorded' is not a slice $slice branch (it should end $sfx)" ;; esac
      git show-ref --verify --quiet "refs/heads/$recorded" \
        || die 14 "$plan recorded branch '$recorded', but it no longer exists — re-stamp and re-approve the plan to start fresh"
      if [ -n "$dirty" ] && [ "$current" != "$recorded" ]; then
        die 12 "uncommitted changes on '$current' — commit or stash them before resuming '$recorded'"
      fi
      [ "$current" = "$recorded" ] || git checkout --quiet "$recorded"
      echo "resuming $recorded (left by an earlier run of this plan)" >&2
      echo "$recorded"
      exit 0
    fi

    # A plan with no branch but a non-empty log ran on a branch that is gone or was cleared.
    # Starting a fresh branch would let the old log claim work that isn't on it.
    # An earlier slice's log, up to its "- slice <k>: <pr> merged" line, belongs to a merged branch.
    logged="$(awk '
      f==0 && /^[ \t]*<!--[ \t]*asdlc:progress[ \t]*-->[ \t\r]*$/ {f=1; next}
      f==1 && /^- slice [0-9]+: .* merged[ \t\r]*$/ {n=0; next}
      f==1 && $0 !~ /^[ \t\r]*$/ && $0 !~ /^## Progress[ \t\r]*$/ {n++}
      END {print n+0}' "$plan")"
    [ "$logged" -eq 0 ] || die 15 "$plan logged progress on a branch that is gone or was cleared — re-stamp and re-approve it"
    [ -z "$dirty" ] || die 12 "uncommitted changes on '${current:-detached HEAD}' — commit or stash them first"
    check_branch_name "TARGET_BRANCH" "$TARGET_BRANCH"
    branch="feature/$key-$(slugify "$summary")$sfx"
    check_branch_name "branch" "$branch"
    if git show-ref --verify --quiet "refs/heads/$branch"; then
      die 13 "branch '$branch' already exists but $plan didn't record it — delete or rename that branch, or set the plan's branch: field to it to resume there"
    fi
    git checkout --quiet "$TARGET_BRANCH" || die 1 "could not check out $TARGET_BRANCH"
    git pull --ff-only --quiet || die 1 "could not fast-forward $TARGET_BRANCH from its upstream"
    # Record first: a crash between the two steps leaves a recorded-but-missing branch (exit 14,
    # re-stamp), never an unrecorded one that blocks forever (exit 13).
    "$PS" set "$plan" branch "$branch" >/dev/null
    if ! git checkout --quiet -b "$branch"; then
      "$PS" set "$plan" branch "" >/dev/null || true
      die 1 "could not create branch '$branch'"
    fi
    echo "created $branch from $TARGET_BRANCH" >&2
    echo "$branch"
    ;;
  next-slice)
    plan="${2:?usage: run-state.sh next-slice <plan>}"
    case "$plan" in
      */*|*.md) ;;
      *) [[ $plan =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die 2 "refusing: a bare plan id must match [A-Za-z0-9][A-Za-z0-9._-]* (or pass a path)"
         plan="./plans/$plan.plan.md" ;;
    esac
    . "$ASDLC_SHARED_SCRIPTS/plan-lib.sh"      # compute_state, slice_info, restore_approved
    compute_state
    case "$STATE" in
      WAITING) ;;
      MISSING) die 16 "no header block in $plan — nothing to advance" ;;
      *) die 2 "refusing: $plan is $STATE, not WAITING — next-slice only follows a slice whose PR is open" ;;
    esac
    if [ "$CUR_HASH" != "$STORED_HASH" ]; then
      die 11 "the approved part of the plan changed since it was approved — re-stamp and have a human re-approve"
    fi
    slice_info || die 2 "refusing: cannot tell which slice this is (see above)"
    [ "$SL_CUR" -lt "$SL_N" ] || die 2 "refusing: slice $SL_CUR is the last slice of $plan (of $SL_N); there is no next slice"
    url="$("$PS" get "$plan" pr)"
    [ -n "$url" ] || die 19 "slice $SL_CUR has no PR recorded in the plan, so its merge cannot be confirmed"
    [ -n "$BB_WORKSPACE" ] && [ -n "$BB_REPO" ] || die 2 "BB_WORKSPACE and BB_REPO must be set in ${ASDLC_CONF_FILE:-.asdlc/jira.conf}"
    bb_err="$(asdlc_check_bb_target 2>&1)" || die 2 "$bb_err"
    pref="https://bitbucket.org/$BB_WORKSPACE/$BB_REPO/pull-requests/"
    pid="${url#"$pref"}"; pid="${pid%/}"
    if [ "$pid" = "$url" ] || ! [[ $pid =~ ^[0-9]{1,9}$ ]]; then
      die 19 "slice $SL_CUR's PR is not a pull request of $BB_WORKSPACE/$BB_REPO on bitbucket.org, so its merge cannot be confirmed"
    fi
    pid=$((10#$pid))
    if [ -z "$ASDLC_FIXTURES" ]; then
      { [ -n "${BITBUCKET_TOKEN:-}" ] && { [ "$BB_AUTH" != basic ] || [ -n "${BITBUCKET_EMAIL:-}" ]; }; } \
        || die 19 "no Bitbucket token (BITBUCKET_TOKEN), so the merge of PR $pid cannot be confirmed; the plan is untouched"
    fi
    errf="$(mktemp)"
    if ! prj="$(asdlc_get_json bb "/repositories/$BB_WORKSPACE/$BB_REPO/pullrequests/$pid" 2>"$errf")"; then
      why="$(tr -cd '[:print:]' <<<"$(head -n1 "$errf")")"; rm -f "$errf"
      die 19 "Bitbucket REST failed for PR $pid ($why), so its merge cannot be confirmed; the plan is untouched"
    fi
    rm -f "$errf"
    pst="$(jq -r '.state // ""' <<<"$prj" 2>/dev/null)" || pst=""
    case "$pst" in
      MERGED) ;;
      OPEN|DECLINED|SUPERSEDED) die 19 "slice $SL_CUR's PR $pid is $pst, not MERGED; the plan is untouched" ;;
      *) die 19 "Bitbucket gave no usable state for PR $pid, so its merge cannot be confirmed; the plan is untouched" ;;
    esac
    rc=0
    restore_approved WAITING "- slice $SL_CUR: $url merged" "slice=$((SL_CUR + 1))" "branch=" "pr=" || rc=$?
    case "$rc" in
      0) ;;
      11) die 11 "the approved part of the plan changed since it was approved — re-stamp and have a human re-approve" ;;
      *) die 2 "refusing: $plan is no longer WAITING" ;;
    esac
    echo "$(plan_id "$plan"): slice $SL_CUR merged; now on slice $((SL_CUR + 1)) of $SL_N (approved)"
    ;;
  *) echo "unknown command: $cmd" >&2; exit 2 ;;
esac
