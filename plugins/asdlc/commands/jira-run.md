---
description: Execute approved Jira plans, then plan new tickets (batched, file-based approval)
argument-hint: "[PROJECT] | --key K | --sprint active|<id>|\"Name\" | --status \"A,B\" | --plan-only | --execute-only | --reset-executing"
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/jira/scripts/jira-conf.sh:*), Bash(${CLAUDE_PLUGIN_ROOT}/jira/scripts/jira-mine.sh:*), Bash(${CLAUDE_PLUGIN_ROOT}/jira/scripts/jira-context.sh:*), Bash(${CLAUDE_PLUGIN_ROOT}/scripts/plan-state.sh stamp:*), Bash(${CLAUDE_PLUGIN_ROOT}/scripts/plan-state.sh check:*), Bash(${CLAUDE_PLUGIN_ROOT}/scripts/plan-state.sh set:*), Bash(${CLAUDE_PLUGIN_ROOT}/scripts/plan-state.sh get:*), Bash(${CLAUDE_PLUGIN_ROOT}/scripts/plan-state.sh validate:*), Bash(${CLAUDE_PLUGIN_ROOT}/scripts/plan-state.sh progress:*), Bash(${CLAUDE_PLUGIN_ROOT}/scripts/impact-scan.sh:*), Bash(${CLAUDE_PLUGIN_ROOT}/jira/scripts/run-state.sh lock:*), Bash(${CLAUDE_PLUGIN_ROOT}/jira/scripts/run-state.sh unlock:*), Bash(${CLAUDE_PLUGIN_ROOT}/jira/scripts/run-state.sh reset-executing:*), Bash(${CLAUDE_PLUGIN_ROOT}/jira/scripts/run-state.sh start-branch:*), Bash(${CLAUDE_PLUGIN_ROOT}/jira/scripts/jira-transition.sh:*), Bash(${CLAUDE_PLUGIN_ROOT}/jira/scripts/review-mode.sh:*), Bash(git status:*), Bash(git add:*), Bash(ls:*), Skill(asdlc:implement-prd), Skill(asdlc:review-pr), Read
---

# /asdlc:jira-run

One run does two phases: first it EXECUTES plans I've already approved, then it PLANS new tickets
and leaves them for me to approve. Approval is never something you do — it only ever comes from me
running `/asdlc:plan approve <KEY>` on a plan file.

Scripts live in `${CLAUDE_PLUGIN_ROOT}/jira/scripts/`. Always call them by that full path, as written
below; run them from the repo root. They read the project's `.asdlc/jira.conf` and the token env vars.

## 0. Config, lock, args
- Read the config: `${CLAUDE_PLUGIN_ROOT}/jira/scripts/jira-conf.sh`. If it fails (no config), tell me
  to run `/asdlc:jira-setup` and STOP. Note `TARGET_BRANCH` — every `<TARGET_BRANCH>` below is that value.
- Take the run lock: `${CLAUDE_PLUGIN_ROOT}/jira/scripts/run-state.sh lock`. It prints a run id: keep it as `<RUN_ID>`.
  - Exit 10 means another run holds the lock. Show me the holder it names (who, since when) and
    STOP. If I tell you that run crashed, I clear it myself, or I tell you to run
    `${CLAUDE_PLUGIN_ROOT}/jira/scripts/run-state.sh force-unlock` — never run that on your own.
  - Always release the lock before you finish, including on error: `${CLAUDE_PLUGIN_ROOT}/jira/scripts/run-state.sh unlock <RUN_ID>`.
- Read the phase flags from the arguments: `--plan-only` (Phase B only), `--execute-only`
  (Phase A only), `--reset-executing` (before Phase A, run `${CLAUDE_PLUGIN_ROOT}/jira/scripts/run-state.sh reset-executing`: every plan a
  crashed run left `executing` goes back to `approved`, if its approved part is unchanged — what
  the run logged under the plan's Progress section doesn't count. Relay what it prints; a plan it
  refuses needs a re-stamp and my re-approval).
  Everything else is a *selection* to hand to jira-mine in Phase B.

## Phase A — execute approved plans   (skip if --plan-only)
List plan files: `ls ./plans/*.plan.md`. For each, run
`${CLAUDE_PLUGIN_ROOT}/scripts/plan-state.sh check <plan>` and act on the word it prints:
- `RUNNABLE` → run `${CLAUDE_PLUGIN_ROOT}/scripts/plan-state.sh validate <plan>`. `VALID` → implement
  it, after the stale check below. `INVALID` → skip; report "<KEY>: plan doesn't validate — re-plan".
- `EDITED` → skip; report "<KEY>: plan edited since approval — re-approve".
- `STALE` → skip; report "<KEY>: ticket changed since approval — re-plan". Phase B re-plans it.
- `NEEDS_INFO` `BLOCKED` → skip; report "<KEY>: <word>".
- `EXECUTING` `PENDING` `DONE` `FAILED` `SKIP` `MISSING` → skip (mention EXECUTING/FAILED, stay quiet on the rest).

Stale check, for each plan that is RUNNABLE and VALID, before anything else is done for it:
`${CLAUDE_PLUGIN_ROOT}/jira/scripts/jira-context.sh check <plan>`. It prints one verdict line, never ticket
text. Never run a plan unless it is RUNNABLE, VALID and FRESH.
- `FRESH` (exit 0) → implement it (steps below).
- `STALE <summary>` (exit 17) → the plan is now `stale` and its `.prev` and `changes.md` exist. Do not
  run it. Report "<KEY>: ticket changed since approval — <summary>", adding the `branch: <name>` line if
  the check printed one (work was already done on it). Queue the plan for Phase B.
- `UNCHECKED <reason>` (exit 21) → do not run it; report "<KEY>: not run — <reason>". The plan is untouched.
- Exit 2 → do not run it; relay the message. A plan with no fingerprint (approved before 1.4.0, or not
  a Jira plan) is reported as "<KEY>: no ticket fingerprint — re-plan".

To implement a plan that is RUNNABLE, VALID and FRESH (KEY = its `ticket` field, read with `plan-state.sh get <plan> ticket`):
1. `${CLAUDE_PLUGIN_ROOT}/jira/scripts/run-state.sh start-branch <plan> "<summary>"` → prints the branch: keep it as `<BRANCH>`.
   - A plan with no branch yet gets a new `feature/<KEY>-<slug>` off an up-to-date
     `<TARGET_BRANCH>`, recorded in the plan. A plan whose earlier run crashed resumes on the
     branch it recorded, with that run's work.
   - Exit 12 (uncommitted changes outside the plan's own branch) → STOP Phase A and report it.
   - Exit 13 (the branch exists but this plan didn't create it) or 14 (the plan's branch is gone)
     → report what it says, next plan. Never delete, reset or reuse a branch yourself.
   - Exit 15 (progress logged on a gone or cleared branch) → report it, next plan. The plan needs
     a re-stamp and my re-approval; never clear its log or branch yourself.
   - Any other non-zero exit (2 refusal, 1 git failure) → report what it says, next plan.
2. `${CLAUDE_PLUGIN_ROOT}/jira/scripts/jira-transition.sh <KEY> :in-progress`
3. Run `/asdlc:implement-prd <plan> --execute` (Skill tool). It re-runs the gate and itself sets the
   plan to `executing`; you don't set it. On a resumed plan it skips the tasks its Progress
   section already shows as passed.
   - Gate failure (it reports a status other than RUNNABLE and STOPs) → report it, next plan.
   - BLOCKED after it started → `${CLAUDE_PLUGIN_ROOT}/scripts/plan-state.sh set <plan> status failed`
     (allowed because the status is `executing`), report, next plan.
4. Commit, push, open PR (confirm each first). Every part checks first, so this step is safe to
   re-run after a crash at any point:
   - Read `${CLAUDE_PLUGIN_ROOT}/scripts/plan-state.sh get <plan> pr`. If it is non-empty, the PR
     already exists (a resumed run that crashed past PR creation): never call `bb-open-pr.sh`
     again, take `<PR_ID>` from the recorded URL (its last path segment) and `<PR_URL>` from the
     plan, and apply only the commit and push checks below before continuing at step 5.
   - Stage only the files the executor reported creating or modifying, plus their tests:
     `git add -- <path> ...`. Never `git add -A` or `git add .`, and never stage `plans/`,
     `prds/`, `.asdlc/` or `.env*`. Then commit only if `git status --short` shows something
     staged: `git commit -m "<KEY> <summary>"`.
   - Push only if `git status -sb` shows the branch ahead of its upstream (or with none yet):
     `git push -u origin <BRANCH>`.
   - Only when no PR is recorded: `${CLAUDE_PLUGIN_ROOT}/jira/scripts/bb-open-pr.sh <BRANCH> "<KEY> <summary>"`
     → capture `<PR_ID> <PR_URL>`, then at once
     `${CLAUDE_PLUGIN_ROOT}/scripts/plan-state.sh set <plan> pr <PR_URL>`
5. Decide review depth from the DIFF, not a guess:
   `${CLAUDE_PLUGIN_ROOT}/jira/scripts/review-mode.sh <TARGET_BRANCH> HEAD "<issue_type>" "<labels_csv>"`
   → prints `council` or `solo` (council when many files/lines changed, a sensitive path is
   touched, or the ticket is Epic/Story/large). Run `/asdlc:review-pr <BRANCH> <TARGET_BRANCH>`,
   appending ` --council` when the mode is `council`.
   - REQUEST_CHANGES → executor fixes on the SAME plan (max 2 cycles), commit, push, re-run the review.
   - APPROVE → (confirm) post the approval summary:
     `${CLAUDE_PLUGIN_ROOT}/jira/scripts/bb-pr-comment.sh <PR_ID> "<summary>"`.
6. `${CLAUDE_PLUGIN_ROOT}/scripts/plan-state.sh set <plan> status done`.
   Report: `<KEY> — <PR_URL> — approved, awaiting merge`.
   The ticket moves to Testing on MERGE (Jira automation), not here.

## Phase B — plan new tickets   (skip if --execute-only)
- Fetch tickets: `${CLAUDE_PLUGIN_ROOT}/jira/scripts/jira-mine.sh <selection>` where `<selection>` is
  the arguments with the phase flags removed. (No selection → my `STATUS_DEFAULT` tickets in
  `JIRA_PROJECT_KEY`.)
- The work list is every plan that is STALE (from Phase A, or any `./plans/*.plan.md` for which
  `plan-state.sh check` prints `STALE`), whatever the selection says, plus each jira-mine ticket
  whose plan file `./plans/<KEY>.plan.md` does NOT exist.
- For EACH key on the work list:
  1. `${CLAUDE_PLUGIN_ROOT}/jira/scripts/jira-context.sh fetch <KEY>` → `./plans/<KEY>/context.md`
     (it prints the path and counts, no ticket text). A STALE plan is moved to `.prev` and its
     `changes.md` kept. Exit 2 → skip it quietly: a plan that is not STALE already exists.
     Any other failure → report it, next key.
  2. Run `/asdlc:implement-prd ./plans/<KEY>/context.md --plan-only` (Skill tool; writes + stamps
     ./plans/<KEY>.plan.md, then stops; on a re-plan it reuses the `.prev` answers and handles `changes.md`)
  3. Report: `<KEY> planned — answer open questions, then /asdlc:plan approve <KEY>`
     (a re-plan: `<KEY> re-planned after ticket change — ...`).
- A plan that is not STALE is left alone, whatever its status — planning never clobbers an approval.
- Never read `./plans/<KEY>/raw/`, `context.md` or `changes.md` yourself: ticket text is for the
  planner and critic. Report from what the scripts print (counts, verdict lines) only.

## Standing authorization (this run)
- Moving a ticket to In Progress (`:in-progress`) may happen automatically.
- On REQUEST_CHANGES you MAY re-run the executor on the same plan automatically, up to 2 cycles, then escalate.
- The plugin pre-approves no commit, push or Bitbucket write. You MUST pause and show me the exact
  command before every commit, push and Bitbucket write (open PR, post comment), then wait for my go.
  The harness also prompts for them unless my own permission settings allow them.
- `${CLAUDE_PLUGIN_ROOT}/jira/scripts/run-state.sh force-unlock` is mine alone: never run it unless I tell you to.
- Plan approval is NEVER yours to give — Phase A only runs plans that already check RUNNABLE and validate VALID.

## Report
Finish with a summary: executed (with PR links), newly planned (awaiting approval), skipped
(edited / stale / unchecked / invalid / executing / blocked). If both phases did nothing, say so. Then release the lock:
`${CLAUDE_PLUGIN_ROOT}/jira/scripts/run-state.sh unlock <RUN_ID>`.
