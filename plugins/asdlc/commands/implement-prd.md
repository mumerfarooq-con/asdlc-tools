---
description: Orchestrate PRD implementation (plan → execute → review → test) or run a retrospective review of an already-completed PRD
argument-hint: <path-to-prd> [--review-only]
---

You are orchestrating work on the PRD at: $ARGUMENTS

Parse the arguments: if `--review-only` is present, run **Retrospective mode**; otherwise run **Pipeline mode**. You coordinate only — route all planning, coding, review, and testing through subagents to keep your context small.

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

## Retrospective mode (--review-only, already-completed PRD)

1. Invoke `prd-reviewer` in retrospective mode with the PRD path (pass the plan file path too if one exists in ./plans/).
2. Relay the report location (`./plans/<slug>.review.md`) and a severity summary (counts of BLOCKER/MAJOR/MINOR).
3. Do NOT auto-invoke the executor on findings — ask the user whether to:
   - turn the "Suggested follow-up tasks" into a fix-up plan via `prd-planner`, then run the normal pipeline on it, or
   - stop here.

## Rules
- Never implement code yourself in this session; all changes go through `prd-executor`.
- Keep per-task commentary to 2–3 lines; plan and review files in ./plans/ are the source of truth for state.
- If context grows large mid-pipeline, /compact and resume from the plan file's task statuses.
