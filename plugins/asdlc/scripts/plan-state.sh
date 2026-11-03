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
#   slice: 1                 # which "## PR slices" row runs next; stamp writes 1 for a plan that has that
#                            #   section (none for any other), outside plan_hash, set refuses it, only
#                            #   run-state.sh next-slice changes it. No line = slice 1.
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
#   plan-state.sh check <plan>               # RUNNABLE|PENDING|EDITED|STALE|NEEDS_INFO|BLOCKED|EXECUTING|WAITING|DONE|FAILED|SKIP|MISSING
#   plan-state.sh set   <plan> <field> <val> # field: status|branch|pr
#   plan-state.sh reset-executing <plan>     # crashed run: executing -> approved, only if the body is unchanged
#   plan-state.sh get   <plan> <field>
#   plan-state.sh validate <plan>            # VALID|INVALID: is the approved part a complete plan?
#   plan-state.sh replan   <plan>            # move the plan to <ID>.plan.prev.md (not while executing)
#   plan-state.sh progress <plan>            # latest Progress entry per task, ordered by task
#   plan-state.sh slice    <plan>            # SLICE <k>/<n> tasks <1,2|all>: the slice that runs next (read-only)
#   plan-state.sh log <plan> <task> <ROLE> <VERDICT> [note]  # append one Progress line (the only writer; below the progress line, hash unchanged)
#   plan-state.sh report-id <plan>           # <KEY>, or <KEY>-s<k> on slice k > 1: names plans/pr-review-<id>.md (read-only; 16 = no header)
#   plan-state.sh find-branch <branch>       # print the one ./plans/*.plan.md whose branch header equals <branch> (read-only; 1 = none, 2 = two claim it or a bad branch)
#   plan-state.sh find-pr <id>               # print the one ./plans/*.plan.md whose pr header ends in /pull-requests/<id> (read-only; same exits)
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
# script, plan-approve.sh, which no command pre-approves (see there). This script has no approve.
# reset-executing restores approved for a plan whose header says executing and whose approved part
# is unchanged. A real guarantee still needs a run record. It and run-state.sh next-slice are the
# only two scripted paths back to approved, both through restore_approved in plan-lib.sh, which is a
# compare-and-set on the human-approved plan_hash (see there). Neither creates an approval.
# "set <plan> status <v>" refuses (exit 2) unless the move is allowed:
#   approved               never
#   executing              only while check says RUNNABLE (approved + hash matches)
#   done | failed          only from executing
#   waiting                only from executing, and only if a later slice exists (a "## PR slices" row
#                          after the current one); its only way out is run-state.sh next-slice
#   pending|skip|rejected|stale|needs-info|blocked  always (they fail closed)
# EDITED means the approved part no longer matches its hash (or a header field / progress line
# is duplicated; the three fingerprint fields count). STALE means the ticket changed after
# approval (status: stale, set by the ticket check; plan-approve.sh refuses a STALE plan, so it
# is re-planned); NEEDS_INFO and BLOCKED are likewise set from outside.
# Exit codes: check = 0 RUNNABLE, 10 PENDING, 11 EDITED, 12 EXECUTING, 13 DONE, 14 FAILED,
# 15 SKIP, 16 MISSING, 17 STALE, 18 NEEDS_INFO, 19 BLOCKED, 21 WAITING. Elsewhere: 2 = refused or bad input;
# 3 = stamp wrote nothing (header not closed, or empty body); 11 = reset-executing found the
# body changed; 16 = no header block; 20 = validate found the plan INVALID (approve exits 20 too,
# and writes nothing).
set -euo pipefail
# plan-lib.sh holds the shared helpers (hash, state, validate); approve is in plan-approve.sh.
. "$(dirname "${BASH_SOURCE[0]}")/plan-lib.sh"

cmd="${1:?usage: plan-state.sh <stamp|check|set|reset-executing|get|validate|replan|progress|slice|report-id|log> <plan|ID>  (or: find-branch <branch> | find-pr <id>) ...}"
# find-branch and find-pr take a branch or a PR id, not a plan, so they run before the plan argument
# is read. They read only the header of each ./plans/*.plan.md (hdr_get), print nothing but the one
# matching path, and refuse a symlinked plans/ (and skip a symlinked plan file). They exist because
# commands have no file search on newer Claude Code builds. Exit 1 = no match; 2 = refused or ambiguous.
if [ "$cmd" = find-branch ] || [ "$cmd" = find-pr ]; then
  [ "$#" -eq 2 ] || die 2 "usage: plan-state.sh find-branch <branch> | find-pr <id>"
  fb="$2"
  if [ "$cmd" = find-branch ]; then
    [ -n "$fb" ] || die 2 "refusing: empty branch"
    case "$fb" in -*) die 2 "refusing: a branch cannot start with '-'" ;; esac
    re_ok "$fb" '^[^[:cntrl:]]*$' || die 2 "refusing: the branch contains a control character"
  else
    re_ok "$fb" '^[0-9]{1,9}$' || die 2 "refusing: a PR id is 1 to 9 digits"
    fb="$((10#$fb))"
  fi
  [ ! -L plans ] || die 2 "refusing: plans is a symbolic link"
  fb_hit=""; fb_n=0
  for fb_f in plans/*.plan.md; do
    [ -f "$fb_f" ] && [ ! -L "$fb_f" ] || continue
    has_block "$fb_f" || continue
    if [ "$cmd" = find-branch ]; then
      [ "$(hdr_get "$fb_f" branch)" = "$fb" ] || continue
    else
      fb_pr="$(hdr_get "$fb_f" pr)"; fb_pr="${fb_pr%/}"
      case "$fb_pr" in */pull-requests/*) ;; *) continue ;; esac
      fb_id="${fb_pr##*/pull-requests/}"
      re_ok "$fb_id" '^[0-9]{1,9}$' && [ "$((10#$fb_id))" -eq "$fb" ] || continue
    fi
    fb_hit="$fb_f"; fb_n=$((fb_n + 1))
  done
  [ "$fb_n" -le 1 ] || die 2 "refusing: more than one plan claims $( [ "$cmd" = find-pr ] && echo "PR $fb" || echo "branch $fb")"
  [ "$fb_n" -eq 1 ] || exit 1
  printf '%s\n' "$fb_hit"
  exit 0
fi
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
          fp_lines="$(read_fingerprint "$fpf")" || die 2 "refusing: $fpf is malformed (want ticket_fingerprint: sha256:<64 hex>, fingerprint_at: <ISO UTC>, fingerprint_source: ${FP_SOURCES// /|}); nothing written"
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
      # Only a plan whose "## PR slices" section holds at least one slice row (slices_part prints
      # one line per slice) gets the field. A plan with no section, or one that keeps only the
      # template's hint row, gets none: its header is byte-identical to a pre-1.6.0 one, and no
      # line reads as slice 1.
      sl_rows="$(approved_part < "$btmp" | slices_part 2>/dev/null || true)"
      if [ -n "$sl_rows" ]; then printf 'slice: 1\n'; fi
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
      slice) die 2 "refusing: slice is changed only by run-state.sh next-slice, once the slice's PR is merged" ;;
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
          executing|waiting|done|failed|pending|skip|rejected|stale|needs-info|blocked) ;;
          *) die 2 "refusing: unknown status '$val' (allowed: pending|executing|waiting|done|failed|skip|rejected|stale|needs-info|blocked)" ;;
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
        waiting)
          [ "$STATE" = EXECUTING ] || die 2 "refusing: waiting only follows executing (this plan is $STATE)"
          slice_info || die 2 "refusing: cannot tell which slice this is (see above)"
          [ "$SL_CUR" -lt "$SL_N" ] || die 2 "refusing: waiting needs a later slice (this plan is on slice $SL_CUR of $SL_N)" ;;
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
    rc=0; restore_approved EXECUTING "" || rc=$?
    [ "$rc" -eq 0 ] || die 11 "the approved part of the plan changed during the crashed run — re-stamp ('plan-state.sh stamp') and have a human re-approve"
    echo "reset $plan: executing -> approved"
    ;;
  get) hdr_get "$plan" "${3:?field required}" ;;
  slice)
    [ -f "$plan" ] || die 2 "no such plan: $plan"
    has_block "$plan" || die 16 "no header block in $plan — run 'plan-state.sh stamp' first"
    slice_info || exit 2
    echo "SLICE $SL_CUR/$SL_N tasks $SL_TASKS"
    ;;
  log)
    # The only writer of Progress lines. The orchestrator calls it with the verdict an agent returned;
    # agents never edit the plan. One line is appended at the very end of the file, which is always
    # below the progress line, so the approved part and its hash are untouched. Same temp-and-move
    # write as write_field. Usage: log <plan> <task> <ROLE> <VERDICT> [note]
    [ -f "$plan" ] || die 2 "no such plan: $plan"
    [ "$#" -ge 5 ] || die 2 "usage: plan-state.sh log <plan> <task> <ROLE> <VERDICT> [note]"
    lg_task="$3"; lg_role="$4"; lg_verd="$5"; lg_note="${6-}"
    case "$lg_role $lg_verd" in
      "EXECUTOR DONE"|"EXECUTOR BLOCKED"|"REVIEW APPROVED"|"REVIEW CHANGES_REQUESTED"|"TEST PASS"|"TEST FAIL") ;;
      *) die 2 "refusing: '$lg_role $lg_verd' is not one of: EXECUTOR DONE, EXECUTOR BLOCKED, REVIEW APPROVED, REVIEW CHANGES_REQUESTED, TEST PASS, TEST FAIL" ;;
    esac
    [ "$#" -le 6 ] || die 2 "refusing: one note argument only (quote it)"
    if has_eol "$lg_task" || ! re_ok "$lg_task" '^[1-9][0-9]{0,3}$'; then die 2 "refusing: the task must be a whole number like 3"; fi
    re_ok "$lg_note" '^[^[:cntrl:]]*$' || die 2 "refusing: the note contains a newline or a control character"
    has_block "$plan" || die 16 "no header block in $plan — run 'plan-state.sh stamp' first"
    [ "$(progress_count "$plan")" -eq 1 ] || die 2 "refusing: $plan has no single '$PROGRESS' line (stamp adds it)"
    lg_part="$(body_of "$plan" | approved_part)"
    printf '%s\n' "$lg_part" | LGN="$lg_task" awk '$0 ~ ("^### Task " ENVIRON["LGN"] "([^0-9]|$)") {f=1} END {exit !f}' \
      || die 2 "refusing: $plan has no '### Task $lg_task' above its progress line"
    [ -n "$lg_note" ] || lg_note="no note"
    # Cut at 300 bytes, then drop a multibyte character the cut split (agents write em dashes).
    lg_note="$(printf '%s' "$lg_note" | LC_ALL=C cut -b1-300)"
    # iconv -c exits 1 when it dropped bytes: keep its output anyway, unless it printed nothing.
    if command -v iconv >/dev/null 2>&1; then
      lg_clean="$(printf '%s' "$lg_note" | iconv -f UTF-8 -t UTF-8 -c 2>/dev/null || true)"
      [ -z "$lg_clean" ] || lg_note="$lg_clean"
    fi
    otmp="$(mktemp)"
    { cat "$plan"
      if [ -n "$(tail -c1 "$plan")" ]; then echo; fi
      printf -- '- Task %s: %s %s — %s\n' "$lg_task" "$lg_role" "$lg_verd" "$lg_note"; } > "$otmp"
    mv "$otmp" "$plan"
    echo "logged Task $lg_task: $lg_role $lg_verd"
    ;;
  report-id)
    # The id that names this plan's review report, plans/pr-review-<id>.md, and its review-pr --id:
    # <KEY>, or <KEY>-s<k> on slice k > 1. Read-only. The one place this rule is written down.
    [ -f "$plan" ] || die 2 "no such plan: $plan"
    has_block "$plan" || die 16 "no header block in $plan — run 'plan-state.sh stamp' first"
    slice_hdr_ok || die 2 "the slice header is not a whole number from 1 to 999"
    rid_key="$(hdr_get "$plan" ticket)"; [ -n "$rid_key" ] || rid_key="$(basename "$plan" .plan.md)"
    rid_k="$(hdr_get "$plan" slice)"; [ -n "$rid_k" ] || rid_k=1
    if [ "$((10#$rid_k))" -gt 1 ]; then echo "$rid_key-s$((10#$rid_k))"; else echo "$rid_key"; fi
    ;;
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
