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
#
# force-unlock is deliberately not a prefix of any other subcommand, so a permission rule
# like "run-state.sh unlock:*" can never pre-approve it.
#
# start-branch prints the branch name on stdout. A plan whose header has no branch gets a new
# feature/<KEY>-<slug> off an up-to-date TARGET_BRANCH. A plan that recorded a branch in an
# earlier, crashed run resumes on that branch. An existing branch the plan didn't record is
# never reused or reset.
#
# Exit codes: 0 ok; 2 bad input or refused; 10 the lock is held; 11 reset-executing refused
# some plan (its approved part changed); 12 the working tree has uncommitted changes;
# 13 the branch exists but this plan didn't record it; 14 the plan's recorded branch is gone.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
ASDLC_CONF_OPTIONAL=1 asdlc_init "$@"; set -- ${ASDLC_ARGS[@]+"${ASDLC_ARGS[@]}"}
PS="$ASDLC_JIRA_HOME/../scripts/plan-state.sh"
PLANS="./plans"
LOCK="$PLANS/.jira-run.lock"

die() { echo "$2" >&2; exit "$1"; }
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

cmd="${1:?usage: run-state.sh <lock|unlock|status|force-unlock|reset-executing|list|start-branch> ...}"
case "$cmd" in
  lock)
    mkdir -p "$PLANS"
    if ! mkdir "$LOCK" 2>/dev/null; then
      die 10 "another /asdlc:jira-run holds the lock: $(lock_holder). If that run crashed, a human can clear it with: run-state.sh force-unlock"
    fi
    id="$(date -u +%Y%m%dT%H%M%SZ)-$$-$RANDOM"
    { echo "run_id: $id"; echo "started: $(now_iso)"; echo "started_epoch: $(date +%s)"
      echo "host: $(hostname 2>/dev/null || echo unknown)"; echo "user: ${USER:-unknown}"; } > "$LOCK/owner"
    echo "$id"
    ;;
  unlock)
    id="${2:?usage: run-state.sh unlock <run-id>}"
    if [ ! -d "$LOCK" ]; then echo "not locked"; exit 0; fi
    held="$(owner_field run_id)"
    [ "$held" = "$id" ] || die 2 "refusing: the lock is $(lock_holder), not by run $id"
    rm -f "$LOCK/owner"; rmdir "$LOCK"
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
      [ "$st" = "EXECUTING" ] || continue
      n=$((n + 1)); id="$("$PS" get "$p" ticket)"; id="${id:-$(basename "$p" .plan.md)}"
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
    { printf 'PLAN\tSTATE\tBRANCH\tPR\n'
      for p in "$PLANS"/*.plan.md; do
      [ -e "$p" ] || continue
        st="$("$PS" check "$p" 2>/dev/null || true)"
        id="$("$PS" get "$p" ticket 2>/dev/null || true)"; id="${id:-$(basename "$p" .plan.md)}"
        printf '%s\t%s\t%s\t%s\n' "$id" "$st" "$("$PS" get "$p" branch 2>/dev/null || true)" "$("$PS" get "$p" pr 2>/dev/null || true)"
      done; } | { command -v column >/dev/null && column -t -s "$(printf '\t')" || cat; }
    ;;
  start-branch)
    plan="${2:?usage: run-state.sh start-branch <plan> <summary>}"; summary="${3-}"
    [ "$("$PS" check "$plan" 2>/dev/null || true)" = "RUNNABLE" ] \
      || die 2 "refusing: $plan is not RUNNABLE ($("$PS" check "$plan" 2>/dev/null || true))"
    key="$("$PS" get "$plan" ticket)"
    recorded="$("$PS" get "$plan" branch)"
    dirty="$(git status --porcelain --untracked-files=no)"
    current="$(git symbolic-ref --short -q HEAD || true)"

    if [ -n "$recorded" ]; then
      # Resume: an earlier run of this plan created the branch, then crashed.
      check_branch_name "recorded branch" "$recorded"
      git show-ref --verify --quiet "refs/heads/$recorded" \
        || die 14 "$plan recorded branch '$recorded', but it no longer exists — clear the plan's branch: field to start fresh"
      if [ -n "$dirty" ] && [ "$current" != "$recorded" ]; then
        die 12 "uncommitted changes on '$current' — commit or stash them before resuming '$recorded'"
      fi
      [ "$current" = "$recorded" ] || git checkout --quiet "$recorded"
      echo "resuming $recorded (left by an earlier run of this plan)" >&2
      echo "$recorded"
      exit 0
    fi

    [ -z "$dirty" ] || die 12 "uncommitted changes on '${current:-detached HEAD}' — commit or stash them first"
    check_branch_name "TARGET_BRANCH" "$TARGET_BRANCH"
    branch="feature/$key-$(slugify "$summary")"
    check_branch_name "branch" "$branch"
    if git show-ref --verify --quiet "refs/heads/$branch"; then
      die 13 "branch '$branch' already exists but $plan didn't record it — delete or rename that branch, or set the plan's branch: field to it to resume there"
    fi
    git checkout --quiet "$TARGET_BRANCH" || die 1 "could not check out $TARGET_BRANCH"
    git pull --ff-only --quiet || die 1 "could not fast-forward $TARGET_BRANCH from its upstream"
    git checkout --quiet -b "$branch"
    "$PS" set "$plan" branch "$branch" >/dev/null
    echo "created $branch from $TARGET_BRANCH" >&2
    echo "$branch"
    ;;
  *) echo "unknown command: $cmd" >&2; exit 2 ;;
esac
