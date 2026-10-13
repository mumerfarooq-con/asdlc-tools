---
description: Execute approved Jira plans, then plan new tickets (batched, file-based approval)
argument-hint: "[PROJECT] | --key K | --sprint active|<id>|\"Name\" | --status \"A,B\" | --plan-only | --execute-only | --reset-executing"
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/jira/scripts/jira-conf.sh:*), Bash(${CLAUDE_PLUGIN_ROOT}/jira/scripts/jira-mine.sh:*), Bash(${CLAUDE_PLUGIN_ROOT}/jira/scripts/ticket-to-prd.sh:*), Bash(${CLAUDE_PLUGIN_ROOT}/scripts/plan-state.sh stamp:*), Bash(${CLAUDE_PLUGIN_ROOT}/scripts/plan-state.sh check:*), Bash(${CLAUDE_PLUGIN_ROOT}/scripts/plan-state.sh set:*), Bash(${CLAUDE_PLUGIN_ROOT}/scripts/plan-state.sh get:*), Bash(${CLAUDE_PLUGIN_ROOT}/jira/scripts/run-state.sh lock:*), Bash(${CLAUDE_PLUGIN_ROOT}/jira/scripts/run-state.sh unlock:*), Bash(${CLAUDE_PLUGIN_ROOT}/jira/scripts/run-state.sh status:*), Bash(${CLAUDE_PLUGIN_ROOT}/jira/scripts/run-state.sh reset-executing:*), Bash(${CLAUDE_PLUGIN_ROOT}/jira/scripts/run-state.sh list:*), Bash(${CLAUDE_PLUGIN_ROOT}/jira/scripts/run-state.sh start-branch:*), Bash(${CLAUDE_PLUGIN_ROOT}/jira/scripts/jira-transition.sh:*), Bash(${CLAUDE_PLUGIN_ROOT}/jira/scripts/review-mode.sh:*), Bash(git status:*), Bash(git add:*), Bash(ls:*), Skill(asdlc:implement-prd), Skill(asdlc:review-pr), Read
---

# /asdlc:jira-run

One run does two phases: first it EXECUTES plans I've already approved, then it PLANS new tickets
and leaves them for me to approve. Approval is never something you do — it only ever comes from me
setting `status: approved` in a plan file.

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
- `RUNNABLE` → implement it (steps below).
- `STALE` → skip; report "<KEY>: plan changed since approval — re-approve".
- `EXECUTING` `PENDING` `DONE` `FAILED` `SKIP` `MISSING` → skip (mention EXECUTING/FAILED, stay quiet on the rest).

To implement a RUNNABLE plan (KEY = its `ticket` field, read with `plan-state.sh get <plan> ticket`):
1. `${CLAUDE_PLUGIN_ROOT}/jira/scripts/run-state.sh start-branch <plan> "<summary>"` → prints the branch: keep it as `<BRANCH>`.
   - A plan with no branch yet gets a new `feature/<KEY>-<slug>` off an up-to-date
     `<TARGET_BRANCH>`, recorded in the plan. A plan whose earlier run crashed resumes on the
     branch it recorded, with that run's work.
   - Exit 12 (uncommitted changes outside the plan's own branch) → STOP Phase A and report it.
   - Exit 13 (the branch exists but this plan didn't create it) or 14 (the plan's branch is gone)
     → report what it says, next plan. Never delete, reset or reuse a branch yourself.
2. `${CLAUDE_PLUGIN_ROOT}/jira/scripts/jira-transition.sh <KEY> :in-progress`
3. Run `/asdlc:implement-prd <plan> --execute` (Skill tool). It re-runs the gate and itself sets the
   plan to `executing`; you don't set it. On a resumed plan it skips the tasks its Progress
   section already shows as passed.
   - Gate failure (it reports a status other than RUNNABLE and STOPs) → report it, next plan.
   - BLOCKED after it started → `${CLAUDE_PLUGIN_ROOT}/scripts/plan-state.sh set <plan> status failed`
     (allowed because the status is `executing`), report, next plan.
4. Commit, push, open PR (confirm each first):
   - Stage only the files the executor reported creating or modifying, plus their tests:
     `git add -- <path> ...`, then `git commit -m "<KEY> <summary>"` ; `git push -u origin <BRANCH>`.
     Never `git add -A` or `git add .`, and never stage `plans/`, `prds/`, `.asdlc/` or `.env*`.
   - `${CLAUDE_PLUGIN_ROOT}/jira/scripts/bb-open-pr.sh <BRANCH> "<KEY> <summary>"`
     → capture `<PR_ID> <PR_URL>`
   - `${CLAUDE_PLUGIN_ROOT}/scripts/plan-state.sh set <plan> pr <PR_URL>`
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
- For EACH ticket whose plan file `./plans/<KEY>.plan.md` does NOT already exist:
  1. `${CLAUDE_PLUGIN_ROOT}/jira/scripts/ticket-to-prd.sh <KEY>`  → ./prds/<KEY>.md
  2. Run `/asdlc:implement-prd ./prds/<KEY>.md --plan-only` (Skill tool; writes + stamps
     ./plans/<KEY>.plan.md, then stops)
  3. Report: `<KEY> planned — awaiting approval`.
- Tickets that already have a plan file (any status) are left alone — planning never clobbers an approval.

## Standing authorization (this run)
- Moving a ticket to In Progress (`:in-progress`) may happen automatically.
- On REQUEST_CHANGES you MAY re-run the executor on the same plan automatically, up to 2 cycles, then escalate.
- The plugin pre-approves no commit, push or Bitbucket write. You MUST pause and show me the exact
  command before every commit, push and Bitbucket write (open PR, post comment), then wait for my go.
  The harness also prompts for them unless my own permission settings allow them.
- `${CLAUDE_PLUGIN_ROOT}/jira/scripts/run-state.sh force-unlock` is mine alone: never run it unless I tell you to.
- Plan approval is NEVER yours to give — Phase A only runs plans that already check RUNNABLE.

## Report
Finish with a summary: executed (with PR links), newly planned (awaiting approval), skipped
(stale / executing / blocked). If both phases did nothing, say so. Then release the lock:
`${CLAUDE_PLUGIN_ROOT}/jira/scripts/run-state.sh unlock <RUN_ID>`.
