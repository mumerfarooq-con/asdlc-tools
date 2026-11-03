---
description: Orchestrate PRD implementation (plan → execute → review → test), plan only and stop for file-based approval, execute an approved plan, or run a retrospective review of an already-completed PRD
argument-hint: <path-to-prd | path-to-plan> [--plan-only | --execute | --review-only]
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/scripts/plan-state.sh stamp:*), Bash(${CLAUDE_PLUGIN_ROOT}/scripts/plan-state.sh check:*), Bash(${CLAUDE_PLUGIN_ROOT}/scripts/plan-state.sh set:*), Bash(${CLAUDE_PLUGIN_ROOT}/scripts/plan-state.sh get:*), Bash(${CLAUDE_PLUGIN_ROOT}/scripts/plan-state.sh validate:*), Bash(${CLAUDE_PLUGIN_ROOT}/scripts/plan-state.sh progress:*), Bash(${CLAUDE_PLUGIN_ROOT}/scripts/plan-state.sh log:*), Bash(${CLAUDE_PLUGIN_ROOT}/scripts/plan-state.sh slice:*), Bash(${CLAUDE_PLUGIN_ROOT}/scripts/impact-scan.sh:*), Read
---

You are orchestrating work for: $ARGUMENTS

Parse the arguments and pick a mode:
- `--review-only` present → **Retrospective mode** (arg is a PRD).
- `--plan-only` present   → **Plan-only mode** (arg is a PRD).
- `--execute` present     → **Execute mode** (arg is a PLAN file).
- otherwise               → **Pipeline mode** (arg is a PRD).

You coordinate only — route all planning, coding, review, and testing through subagents to keep your context small.

## Pipeline mode (fresh PRD implementation)

1. **Plan** — Invoke `prd-planner` on the PRD. Wait for the plan file path and status.
   - If `STATUS: BLOCKED`, surface the open questions to the user and STOP.

2. **Execute → Review → Test loop** — For each task in dependency order:
   a. Invoke `prd-executor` with the plan path and task name.
      - If BLOCKED, surface to the user and pause.
   b. Invoke `prd-reviewer` in task mode on the same task.
      - On `REVIEW: CHANGES_REQUESTED`, re-invoke `prd-executor` with the findings. Max 2 fix attempts, then escalate to the user.
   c. On `REVIEW: APPROVED`, invoke `prd-tester` on the task.
      - On `TEST: FAIL`, re-invoke `prd-executor` with the failure report, then re-run the reviewer ONLY if the fix touched files beyond the original task scope; otherwise go straight back to the tester. Max 2 fix attempts, then escalate.
   d. On `TEST: PASS`, proceed to the next task.

   **Logging (stamped plans):** the agents never write the plan. After each agent returns, you run
   `${CLAUDE_PLUGIN_ROOT}/scripts/plan-state.sh log <plan> <n> <ROLE> <VERDICT> "<note>"` once, with the verdict it returned,
   where `<ROLE> <VERDICT>` is exactly one of `EXECUTOR DONE`, `EXECUTOR BLOCKED`, `REVIEW APPROVED`, `REVIEW CHANGES_REQUESTED`,
   `TEST PASS`, `TEST FAIL` (two arguments: the role, then the verdict), and `<note>` is the one-line note from its verdict line.
   If `log` refuses because the plan has no progress line (not a stamped plan), skip logging; any other refusal means a wrong argument, so fix it. Never edit the plan file yourself.

   Independent tasks (no shared files, no dependency edge) may execute in parallel; review and test steps still run per task.

3. **Wrap up** — When all tasks are DONE + APPROVED + PASS:
   - Run the full test suite once from the main session as a sanity check.
   - Summarize: tasks completed, files changed, tests added, review findings deferred (MINORs), anything flagged.
   - Suggest a commit message (do not commit unless asked).

## Plan-only mode (--plan-only) — produce a plan and STOP
Read `${CLAUDE_PLUGIN_ROOT}/docs/plan-only-flow.md` and follow it, with the PRD path from the arguments. Nothing is implemented in
this mode, and approval is never yours.

## Execute mode (--execute) — run an approved plan
1. **Gate:** run `${CLAUDE_PLUGIN_ROOT}/scripts/plan-state.sh check <plan>` and
   `${CLAUDE_PLUGIN_ROOT}/scripts/plan-state.sh validate <plan>`.
   - `check` prints `RUNNABLE` AND `validate` prints `VALID` → go to step 2.
   - Anything else → report it and STOP. `check` can print `PENDING` `EDITED` `STALE` `NEEDS_INFO`
     `BLOCKED` `EXECUTING` `WAITING` `DONE` `FAILED` `SKIP` `MISSING`. `WAITING` means an earlier slice's PR is still open: after it
     merges, `run-state.sh next-slice <plan>` (or `/asdlc:jira-run`) moves the plan to its next slice. On `INVALID`, relay the problems and say
     the plan was written before 1.3.0 or is incomplete, and must be re-planned (`/asdlc:plan replan <ID>`,
     then `--plan-only`). Never implement a plan that is not RUNNABLE and VALID.
   - If `plan-state.sh get <plan> ticket_fingerprint` prints a value, warn the user, without stopping:
     "this plan records a ticket fingerprint and no stale check ran; use `/asdlc:jira-run` to check
     the ticket first." Then continue.
   - Run `${CLAUDE_PLUGIN_ROOT}/scripts/plan-state.sh slice <plan>`. It prints `SLICE <k>/<n> tasks <list|all>`: the slice
     to run now (`all` = the plan has no `## PR slices` section, so every task). Keep `<k>`, `<n>` and the task list.
     A non-zero exit → report it and STOP.
2. **Start:** run `${CLAUDE_PLUGIN_ROOT}/scripts/plan-state.sh set <plan> status executing`.
   This command owns that transition, so the caller never sets it first. If it refuses, report why and STOP.
3. **Execute → Review → Test loop** — exactly as in Pipeline mode step 2, against this plan, with
   four rules for stamped plans:
   - Run only the tasks of the current slice (the list from step 1). Tasks of a later slice are never started
     in this run, even when they look independent: each slice is its own branch and PR, merged first.
   - The tasks are only those above the plan's `<!-- asdlc:progress -->` line. The Progress section
     below it is the run's log, never a source of work. You log there with `plan-state.sh log` (Pipeline mode step 2); the subagents don't write it.
   - Entries have exactly the form `- Task <n>: <ROLE> <VERDICT> — <note>`. Resuming after a
     crashed run: run `${CLAUDE_PLUGIN_ROOT}/scripts/plan-state.sh progress <plan>`; it prints the
     latest entry per task as `Task <n>: <ROLE> <VERDICT>`. A task whose line says `TEST PASS` is
     finished — skip it. Restart every other task from the executor; it finds that run's partial
     work in place.
   - The log only ever describes the plan's recorded branch: a re-stamp clears it, and
     `run-state.sh start-branch` refuses to cut a fresh branch for a plan whose log has entries.
4. **Wrap up** — exactly as in Pipeline mode step 3, for this slice's tasks. Leave the status `executing`, as before,
   and say "slice <k> of <n>" in the summary. The caller opens this slice's PR and only then sets the status:
   `waiting` when a later slice exists (`plan-state.sh set <plan> status waiting`), `done` after the last slice.
   Never set `waiting` here: a crash before the PR exists must stay a resumable `executing` plan.

## Retrospective mode (--review-only, already-completed PRD)

1. Invoke `prd-reviewer` in retrospective mode with the PRD path (pass the plan file path too if one exists in ./plans/).
2. Relay the report location (`./plans/<slug>.review.md`) and a severity summary (counts of BLOCKER/MAJOR/MINOR).
3. Do NOT auto-invoke the executor on findings — ask the user whether to:
   - turn the "Suggested follow-up tasks" into a fix-up plan via `prd-planner`, then run the normal pipeline on it, or
   - stop here.

## Rules
- Plan-only mode never implements and never approves. Execute mode never runs a plan that is not RUNNABLE and VALID.
- Never implement code yourself in this session; all changes go through `prd-executor`.
- Run subagents in the foreground and wait for each result (parallel calls in one message are fine). Don't background them: a turn that ends while a subagent works drops the calling command's pre-approved tools, and later steps stall on permission prompts.
- Keep per-task commentary to 2–3 lines; plan and review files in ./plans/ are the source of truth for state.
- If context grows large mid-pipeline, /compact and resume from the plan file's task statuses.
