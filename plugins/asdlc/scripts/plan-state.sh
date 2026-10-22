#!/usr/bin/env bash
# Deterministic state + hashing for plan files (/asdlc:implement-prd --plan-only and
# --execute, /asdlc:jira-run). Header block (HTML comment) at the TOP of ./plans/<ID>.plan.md:
#   <!-- asdlc
#   ticket: PROJ-142
#   status: pending          # you change this to: approved
#   plan_hash: sha256:<hex>  # tool-stamped over the plan body — do not edit
#   ticket_fingerprint: sha256:<hex>   # Jira plans only: copied by stamp from plans/<ID>/fingerprint
#   fingerprint_at: <iso8601>          #   (written by jira-context.sh build); outside plan_hash,
#   fingerprint_source: rest           #   like branch; set refuses all three
#   branch:
#   pr:
#   updated: <iso8601>
#   -->
#   <plan body: the approved part>
#   <!-- asdlc:progress -->
#   ## Progress
#   <run log: agents append task status, notes and verdicts here>
# Plans written by the pre-plugin in-repo version open with "<!-- jira-run:approval";
# those are read the same way and get the current marker the next time they are stamped.
#
# Usage:
#   plan-state.sh stamp <plan> [ticket]      # (re)write block: status=pending, fresh hash, empty log
#   plan-state.sh check <plan>               # RUNNABLE|PENDING|EDITED|STALE|NEEDS_INFO|BLOCKED|EXECUTING|DONE|FAILED|SKIP|MISSING
#   plan-state.sh set   <plan> <field> <val> # field: status|branch|pr
#   plan-state.sh reset-executing <plan>     # crashed run: executing -> approved, only if the body is unchanged
#   plan-state.sh get   <plan> <field>
#   plan-state.sh validate <plan>            # VALID|INVALID: is the approved part a complete plan?
#   plan-state.sh replan   <plan>            # move the plan to <ID>.plan.prev.md (not while executing)
#   plan-state.sh progress <plan>            # latest Progress entry per task, ordered by task
# <plan> is a path, or a bare ticket id (no '/', not ending .md) meaning ./plans/<ID>.plan.md.
#
# The contract: above the progress line is everything a human signs off on (M2's Critic notes
# and Open-question answers included); below it is only the machine run log, never a source of
# work. stamp places the line (and refuses a plan that already has one, so plan templates must
# not contain it); approve recomputes the hash over the part above the line.
# plan_hash covers only the approved part, the body up to the progress line, taken as sha256 of
# "asdlc-plan-v2\n" + that part. Agents log a run's progress below the line, so ticking tasks
# never invalidates the approval and a crashed run can be resumed. A plan with no line (stamped
# before 1.2.0) keeps the plain whole-body hash and stays RUNNABLE; once such a plan gains a
# line it is EDITED, because the line is never hashed the legacy way again. A progress line is
# any line matching: optional blanks, <!--, asdlc:progress, -->, optional blanks or CR.
# Re-stamping is a new approval and a new run, so it empties the log.
#
# Approval is a human act: "set status approved" is refused, and approving lives in its own
# script, plan-approve.sh, which no command pre-approves (see there). This script has no approve. reset-executing restores approved for a plan whose header says executing and whose
# approved part is unchanged. A real guarantee still needs a run record.
# "set <plan> status <v>" refuses (exit 2) unless the move is allowed:
#   approved               never
#   executing              only while check says RUNNABLE (approved + hash matches)
#   done | failed          only from executing
#   pending|skip|rejected|stale|needs-info|blocked  always (they fail closed)
# EDITED means the approved part no longer matches its hash (or a header field / progress line
# is duplicated; the three fingerprint fields count). STALE means the ticket changed after
# approval (status: stale, set by the ticket check; plan-approve.sh refuses a STALE plan, so it
# is re-planned); NEEDS_INFO and BLOCKED are likewise set from outside.
# Exit codes: check = 0 RUNNABLE, 10 PENDING, 11 EDITED, 12 EXECUTING, 13 DONE, 14 FAILED,
# 15 SKIP, 16 MISSING, 17 STALE, 18 NEEDS_INFO, 19 BLOCKED. Elsewhere: 2 = refused or bad input;
# 3 = stamp wrote nothing (header not closed, or empty body); 11 = reset-executing found the
# body changed; 16 = no header block; 20 = validate found the plan INVALID (approve exits 20 too,
# and writes nothing).
set -euo pipefail
# plan-lib.sh holds the shared helpers (hash, state, validate); approve is in plan-approve.sh.
. "$(dirname "${BASH_SOURCE[0]}")/plan-lib.sh"

cmd="${1:?usage: plan-state.sh <stamp|check|set|reset-executing|get|validate|replan|progress> <plan|ID> ...}"
plan="${2:?plan file or ticket id required}"
# A bare ID (no '/', not ending .md) means ./plans/<ID>.plan.md; it must look like a ticket id.
case "$plan" in
  */*|*.md) ;;
  *) if has_eol "$plan" || ! re_ok "$plan" '^[A-Za-z0-9][A-Za-z0-9._-]*$'; then
       die 2 "refusing: a bare plan id must match [A-Za-z0-9][A-Za-z0-9._-]* (or pass a path)"
     fi
     plan="./plans/$plan.plan.md" ;;
esac

case "$cmd" in
  stamp)
    ticket="${3:-$(basename "$plan" .plan.md)}"
    # The ticket lands in the header, so it must not carry a newline or anything odd.
    if has_eol "$ticket" || ! re_ok "$ticket" '^[A-Za-z0-9][A-Za-z0-9._-]*$'; then
      die 2 "refusing: ticket must match [A-Za-z0-9][A-Za-z0-9._-]* (a key like PROJ-142 or a PRD basename)"
    fi
    # Guards first; the plan is only replaced after every one passes.
    if has_block "$plan" && ! has_close "$plan"; then
      die 3 "header block not closed in $plan — no line is exactly '-->' at column 0; nothing written"
    fi
    btmp="$(mktemp)"; body_of "$plan" > "$btmp"
    pc="$(progress_count "$plan")"
    if [ "$pc" -gt 1 ]; then
      die 3 "more than one '$PROGRESS' line in $plan — keep exactly one, after the plan; nothing written"
    fi
    if [ "$pc" -eq 1 ] && ! has_block "$plan"; then
      die 3 "stamp adds the progress line itself; remove it from the plan; nothing written"
    fi
    if [ -z "$(approved_part < "$btmp" | LC_ALL=C tr -d ' \t\r\n\f\v')" ]; then
      die 3 "empty plan body in $plan — nothing to stamp; nothing written"
    fi
    if [ "$pc" -eq 0 ]; then
      # Give the run a fixed place to log progress, outside the approved part.
      { if [ -n "$(tail -n1 "$btmp")" ]; then echo; fi
        printf '%s\n' "$PROGRESS" '## Progress'; } >> "$btmp"
    else
      # Re-stamp: the line must be followed by "## Progress" and then the log. The log is dropped
      # because a re-stamp is a new approval and a new run.
      dropped="$(awk -v re="$PROGRESS_AWK" '
        f==0 && $0 ~ re {f=1; next}
        f==1 && $0 ~ /^[ \t\r]*$/ {next}
        f==1 {if ($0 ~ /^## Progress[ \t\r]*$/) {f=2; next} else {f=-1; exit}}
        f==2 && $0 !~ /^[ \t\r]*$/ {n++}
        END {if (f==-1 || f==1) print "bad"; else print n+0}' "$btmp")"
      if [ "$dropped" = bad ]; then
        die 3 "the '$PROGRESS' line in $plan must be followed by '## Progress' — fix or remove it; nothing written"
      fi
      { approved_part < "$btmp"; printf '%s\n' "$PROGRESS" '## Progress'; } > "$btmp.new"
      mv "$btmp.new" "$btmp"
      if [ "$dropped" -gt 0 ]; then echo "dropped $dropped progress log line(s)" >&2; fi
    fi
    # Jira plans: the fingerprint of the ticket text the plan was built from, written by
    # jira-context.sh build. All three lines are checked before anything is written.
    fp_lines=""
    case "$plan" in
      *.plan.md)
        fpf="${plan%.plan.md}/fingerprint"
        if [ -f "$fpf" ]; then
          fp_lines="$(read_fingerprint "$fpf")" || die 2 "refusing: $fpf is malformed (want ticket_fingerprint: sha256:<64 hex>, fingerprint_at: <ISO UTC>, fingerprint_source: rest|mcp); nothing written"
        fi ;;
    esac
    h="$(hash_body 1 < "$btmp")"
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    otmp="$(mktemp)"
    { printf '%s\n' "$MARKER"
      printf 'ticket: %s\n' "$ticket"
      printf 'status: pending\n'
      printf 'plan_hash: sha256:%s\n' "$h"
      if [ -n "$fp_lines" ]; then printf '%s\n' "$fp_lines"; fi
      printf 'branch:\n'; printf 'pr:\n'
      printf 'updated: %s\n' "$now"
      printf '%s\n' '-->'
      cat "$btmp"; } > "$otmp"
    mv "$otmp" "$plan"
    echo "stamped $plan (pending, sha256:${h:0:12}…)"
    ;;
  check)
    compute_state
    echo "$STATE"
    if [ -n "$STATE_MSG" ]; then echo "$STATE_MSG" >&2; fi
    exit "$STATE_CODE"
    ;;
  set)
    field="${3:?field required (status|branch|pr)}"; val="${4-}"
    case "$field" in
      status|branch|pr) ;;
      ticket_fingerprint|fingerprint_at|fingerprint_source)
        die 2 "refusing: $field is copied by stamp from the fingerprint file; re-plan to change it" ;;
      *) echo "field must be status|branch|pr" >&2; exit 2 ;;
    esac
    # Validate the value before touching the file: it is written into the header.
    if has_eol "$val"; then die 2 "refusing: the $field value contains a newline or carriage return"; fi
    case "$field" in
      status)
        case "$val" in
          approved) die 2 "refusing: approval is a human edit of the plan file" ;;
          executing|done|failed|pending|skip|rejected|stale|needs-info|blocked) ;;
          *) die 2 "refusing: unknown status '$val' (allowed: pending|executing|done|failed|skip|rejected|stale|needs-info|blocked)" ;;
        esac ;;
      branch)
        re_ok "$val" '^[A-Za-z0-9._/-]*$' || die 2 "refusing: branch may only contain [A-Za-z0-9._/-]" ;;
      pr)
        [ -z "$val" ] || re_ok "$val" '^https://[^[:space:]]+$' || die 2 "refusing: pr must be empty or an https:// URL with no whitespace" ;;
    esac
    has_block "$plan" || die 16 "no header block in $plan — run 'plan-state.sh stamp' first"
    if [ "$field" = status ]; then
      compute_state
      case "$val" in
        executing)
          [ "$STATE" = RUNNABLE ] || die 2 "refusing: executing needs a RUNNABLE plan (this one is $STATE)" ;;
        done|failed)
          # failed never enables execution, so it is also allowed from executing + EDITED.
          [ "$STATE" = EXECUTING ] || { [ "$val" = failed ] && [ "$STATE" = EDITED ] && [ "$(hdr_get "$plan" status)" = executing ]; } || die 2 "refusing: '$val' only follows executing (this plan is $STATE)" ;;
      esac
    fi
    write_field "$field" "$val"
    echo "set $field=$val on $plan"
    ;;
  reset-executing)
    compute_state
    case "$STATE" in
      EXECUTING) ;;
      MISSING) die 16 "no header block in $plan — nothing to reset" ;;
      *) die 2 "refusing: $plan is $STATE, not EXECUTING — reset-executing only recovers a crashed run" ;;
    esac
    # Compare-and-set: the approval only carries over if the approved body is untouched.
    if [ "$CUR_HASH" != "$STORED_HASH" ]; then
      die 11 "the approved part of the plan changed during the crashed run — re-stamp ('plan-state.sh stamp') and have a human re-approve"
    fi
    write_field status approved
    echo "reset $plan: executing -> approved"
    ;;
  get) hdr_get "$plan" "${3:?field required}" ;;
  validate)
    [ -f "$plan" ] || die 2 "no such plan: $plan"
    do_validate || exit $?
    ;;
  replan)
    [ -f "$plan" ] || die 2 "no such plan: $plan"
    case "$plan" in *.plan.md) ;; *) die 2 "refusing: $plan is not a *.plan.md file" ;; esac
    if has_block "$plan" && [ "$(hdr_get "$plan" status)" = executing ]; then
      die 2 "refusing: $plan is executing — wait for the run, or 'run-state.sh reset-executing' after a crash"
    fi
    prev="${plan%.plan.md}.plan.prev.md"
    mv -f "$plan" "$prev"
    echo "moved $plan to $prev; the next planning run will re-plan it, reusing the answers in $prev"
    ;;
  progress)
    [ -f "$plan" ] || die 2 "no such plan: $plan"
    # Only the entry grammar counts; everything else below the line is ignored.
    body_of "$plan" | awk -v re="$PROGRESS_AWK" '
      f == 0 && $0 ~ re {f = 1; next}
      f == 1 && $0 ~ /^- Task [0-9]+: (EXECUTOR (DONE|BLOCKED)|REVIEW (APPROVED|CHANGES_REQUESTED)|TEST (PASS|FAIL)) — / {
        n = $3; sub(/:$/, "", n); n = n + 0
        v = $4 " " $5
        print n, v
      }' | awk '{ n = $1; sub(/^[0-9]+ /, ""); last[n] = $0; if (!(n in seen)) { seen[n] = 1; order[++c] = n } }
                END { for (i = 1; i <= c; i++) print order[i] "\t" last[order[i]] }' \
      | sort -n | awk -F'\t' '{ print "Task " $1 ": " $2 }'
    ;;
  *)   echo "unknown command: $cmd" >&2; exit 2 ;;
esac
