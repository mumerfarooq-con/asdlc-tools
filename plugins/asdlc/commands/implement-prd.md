---
description: Orchestrate PRD implementation (plan → execute → review → test), plan only and stop for file-based approval, execute an approved plan, or run a retrospective review of an already-completed PRD
argument-hint: <path-to-prd | path-to-plan> [--plan-only | --execute | --review-only]
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/jira/scripts/plan-state.sh stamp:*), Bash(${CLAUDE_PLUGIN_ROOT}/jira/scripts/plan-state.sh check:*), Bash(${CLAUDE_PLUGIN_ROOT}/jira/scripts/plan-state.sh set:*)
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

   Independent tasks (no shared files, no dependency edge) may execute in parallel; review and test steps still run per task.

3. **Wrap up** — When all tasks are DONE + APPROVED + PASS:
   - Run the full test suite once from the main session as a sanity check.
   - Summarize: tasks completed, files changed, tests added, review findings deferred (MINORs), anything flagged.
   - Suggest a commit message (do not commit unless asked).

## Plan-only mode (--plan-only) — produce a plan and STOP
Nothing is implemented in this mode. Approval is not interactive; it lives in the plan file.
1. Invoke `prd-planner` on the PRD. Write the plan to `./plans/<KEY>.plan.md`, where `<KEY>` is
   the ticket key from the PRD's title (fall back to the PRD file's basename).
   - If `STATUS: BLOCKED`, surface the open questions and STOP.
2. Stamp it: `${CLAUDE_PLUGIN_ROOT}/jira/scripts/plan-state.sh stamp ./plans/<KEY>.plan.md <KEY>`
   (writes the header block: `status: pending` + a hash of the plan body).
3. Tell the user the plan is written and awaiting approval. To approve: open the file, read the
   plan, and set `status: approved` in the header block — then run
   `/asdlc:implement-prd ./plans/<KEY>.plan.md --execute` (or let `/asdlc:jira-run` pick it up). STOP.

## Execute mode (--execute) — run an approved plan
1. **Gate:** run `${CLAUDE_PLUGIN_ROOT}/jira/scripts/plan-state.sh check <plan>`.
   - Output `RUNNABLE` → go to step 2.
   - Anything else (`PENDING` `STALE` `EXECUTING` `DONE` `FAILED` `SKIP` `MISSING`) → report it and STOP.
     Never implement a plan that is not RUNNABLE.
2. **Start:** run `${CLAUDE_PLUGIN_ROOT}/jira/scripts/plan-state.sh set <plan> status executing`.
   This command owns that transition, so the caller never sets it first. If it refuses, report why and STOP.
3. **Execute → Review → Test loop** — exactly as in Pipeline mode step 2, against this plan.
4. **Wrap up** — exactly as in Pipeline mode step 3.

## Retrospective mode (--review-only, already-completed PRD)

1. Invoke `prd-reviewer` in retrospective mode with the PRD path (pass the plan file path too if one exists in ./plans/).
2. Relay the report location (`./plans/<slug>.review.md`) and a severity summary (counts of BLOCKER/MAJOR/MINOR).
3. Do NOT auto-invoke the executor on findings — ask the user whether to:
   - turn the "Suggested follow-up tasks" into a fix-up plan via `prd-planner`, then run the normal pipeline on it, or
   - stop here.

## Rules
- Plan-only mode never implements. Execute mode never runs a non-RUNNABLE plan.
- Never implement code yourself in this session; all changes go through `prd-executor`.
- Run subagents in the foreground and wait for each result (parallel calls in one message are fine). Don't background them: a turn that ends while a subagent works drops the calling command's pre-approved tools, and later steps stall on permission prompts.
- Keep per-task commentary to 2–3 lines; plan and review files in ./plans/ are the source of truth for state.
- If context grows large mid-pipeline, /compact and resume from the plan file's task statuses.
