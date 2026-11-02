---
description: Execute approved Jira plans, then plan new tickets (batched, file-based approval)
argument-hint: "[PROJECT] | --key K | --sprint active|<id>|\"Name\" | --status \"A,B\" | --plan-only | --execute-only | --reset-executing"
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/jira/scripts/jira-conf.sh:*), Bash(${CLAUDE_PLUGIN_ROOT}/jira/scripts/jira-mine.sh:*), Bash(${CLAUDE_PLUGIN_ROOT}/jira/scripts/jira-context.sh:*), Bash(${CLAUDE_PLUGIN_ROOT}/scripts/plan-state.sh stamp:*), Bash(${CLAUDE_PLUGIN_ROOT}/scripts/plan-state.sh check:*), Bash(${CLAUDE_PLUGIN_ROOT}/scripts/plan-state.sh set:*), Bash(${CLAUDE_PLUGIN_ROOT}/scripts/plan-state.sh get:*), Bash(${CLAUDE_PLUGIN_ROOT}/scripts/plan-state.sh validate:*), Bash(${CLAUDE_PLUGIN_ROOT}/scripts/plan-state.sh progress:*), Bash(${CLAUDE_PLUGIN_ROOT}/scripts/plan-state.sh slice:*), Bash(${CLAUDE_PLUGIN_ROOT}/scripts/impact-scan.sh:*), Bash(${CLAUDE_PLUGIN_ROOT}/jira/scripts/run-state.sh lock:*), Bash(${CLAUDE_PLUGIN_ROOT}/jira/scripts/run-state.sh unlock:*), Bash(${CLAUDE_PLUGIN_ROOT}/jira/scripts/run-state.sh reset-executing:*), Bash(${CLAUDE_PLUGIN_ROOT}/jira/scripts/run-state.sh start-branch:*), Bash(${CLAUDE_PLUGIN_ROOT}/jira/scripts/run-state.sh next-slice:*), Bash(${CLAUDE_PLUGIN_ROOT}/jira/scripts/jira-transition.sh:*), Bash(${CLAUDE_PLUGIN_ROOT}/jira/scripts/review-mode.sh:*), Bash(${CLAUDE_PLUGIN_ROOT}/jira/scripts/review-queue.sh:*), Bash(${CLAUDE_PLUGIN_ROOT}/scripts/review-report.sh:*), Bash(${CLAUDE_PLUGIN_ROOT}/scripts/review-brief.sh:*), Bash(${CLAUDE_PLUGIN_ROOT}/jira/scripts/review-record.sh last:*), Bash(git status:*), Bash(git add:*), Bash(ls:*), Skill(asdlc:implement-prd), Skill(asdlc:review-pr), Read, mcp__claude_ai_Atlassian__getJiraIssue, mcp__claude_ai_Atlassian__searchJiraIssuesUsingJql, mcp__claude_ai_Atlassian__getTransitionsForJiraIssue, mcp__claude_ai_Atlassian__transitionJiraIssue
---

# /asdlc:jira-run

One run does two phases: first it EXECUTES plans I've already approved, then it PLANS new tickets
and leaves them for me to approve. Approval is never something you do — it only ever comes from me
running `/asdlc:plan approve <KEY>` on a plan file.

Atlassian MCP rule, for every step below: call an Atlassian MCP tool ONLY with the args a script
printed (or that the capture hook's receipt tells you to use), unchanged, and never read its raw
output. While a request is open, the plugin's hook stores the response and shows you a receipt
(counts, no ticket text); the scripts read what was stored. The only Atlassian write you may make is the
one a script printed (`transitionJiraIssue`, or the comment of "Jira writes over MCP" with my confirmation);
never call `editJiraIssue`, `createJiraIssue` or a worklog tool here.

Scripts live in `${CLAUDE_PLUGIN_ROOT}/jira/scripts/`. Always call them by that full path, as written
below; run them from the repo root. They read the project's `.asdlc/jira.conf` and the token env vars.

## 0. Config, lock, args
- Read the config: `${CLAUDE_PLUGIN_ROOT}/jira/scripts/jira-conf.sh`. If it fails (no config), tell me
  to run `/asdlc:jira-setup` and STOP. Note `TARGET_BRANCH` — every `<TARGET_BRANCH>` below is that value.
- Resolve the transport: `${CLAUDE_PLUGIN_ROOT}/jira/scripts/jira-context.sh transport` (no network)
  prints `transport=<auto, mcp or rest> mcp_server=<name> rest_ready=yes|no(<reason>)`. Keep `<TRANSPORT>`
  (`mcp` or `rest`) for the run. `mcp_available` means `mcp__<mcp_server>__getJiraIssue` is among
  your tools (if the tool list is deferred, load it with ToolSearch first). Exit 2 → relay and STOP.
  - `rest` → `<TRANSPORT>` is `rest`.
  - `mcp` → `<TRANSPORT>` is `mcp`. If MCP is not available, STOP and say "connect the Atlassian MCP (/mcp)".
  - `auto` → `mcp` if MCP is available, else `rest` if `rest_ready=yes`, else STOP and say
    "connect the Atlassian MCP (/mcp), or set JIRA_EMAIL and JIRA_TOKEN".
  - The tool pre-approvals below name the default server (`claude_ai_Atlassian`); for another
    `mcp_server` I will be asked to approve the calls.
- Take the run lock: `${CLAUDE_PLUGIN_ROOT}/jira/scripts/run-state.sh lock`. It prints a run id: keep it as `<RUN_ID>`.
  - `run-state.sh lock` exit 10 means another run holds the lock. Show me the holder it names (who, since when) and
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
First the review queue, before any `start-branch`: `${CLAUDE_PLUGIN_ROOT}/jira/scripts/review-queue.sh` (read-only; keep
its output for the Report). It prints `QUEUE <waiting>/<max>` and one `PR <id> <KEY> ...` line per PR still waiting for my
human review (`REVIEW_QUEUE_MAX`, default 3, 0 = no cap).
- `review-queue.sh` exit 18 (at or over the cap) → execute NOTHING this run: the plans stay approved. Report "Review queue full
  (<w>/<max>): review these first — /asdlc:review-tour <PR>", one line per waiting PR, then go to Phase B.
- `review-queue.sh` exit 2 → relay the message and skip Phase A (a bad `REVIEW_QUEUE_MAX` is mine to fix); Phase B still runs.
- `review-queue.sh` exit 0 → carry on. Run `review-queue.sh` again after each PR you open (step 4): exit 18 → stop Phase A there, and report the
  plans you did not run as "<KEY>: not run — review queue full".

List plan files: `ls ./plans/*.plan.md`. For each, run
`${CLAUDE_PLUGIN_ROOT}/scripts/plan-state.sh check <plan>` and act on the word it prints:
- `RUNNABLE` → run `${CLAUDE_PLUGIN_ROOT}/scripts/plan-state.sh validate <plan>`. `VALID` → implement
  it, after the stale check below. `INVALID` → skip; report "<KEY>: plan doesn't validate — re-plan".
- `EDITED` → skip; report "<KEY>: plan edited since approval — re-approve".
- `STALE` → skip; report "<KEY>: ticket changed since approval — re-plan". Phase B re-plans it (in this run, or in the next planning run under `--execute-only`).
- `NEEDS_INFO` `BLOCKED` → skip; report "<KEY>: <word>".
- `WAITING` → the plan is split into PR slices and an earlier slice's PR is open. Read `${CLAUDE_PLUGIN_ROOT}/scripts/plan-state.sh get <plan> pr`:
  empty → skip; report "<KEY>: slice <k> is done but has no PR recorded — open it, or re-stamp" (never open one yourself here).
  Otherwise run `${CLAUDE_PLUGIN_ROOT}/jira/scripts/run-state.sh next-slice <plan>` (read-only against Bitbucket; it moves the plan
  on only if Bitbucket says that PR is MERGED, and never otherwise):
  - `next-slice` exit 0 → the plan is on its next slice and `check` now prints `RUNNABLE`. Treat it as RUNNABLE from the top: `validate`, the
    stale check below (it runs before EVERY slice), then implement it (`<k>` = its new slice).
  - `next-slice` exit 19 → skip; report "<KEY>: slice <k> PR not merged yet" (with the reason it printed).
  - `next-slice` exit 11 → skip; report "<KEY>: plan edited since approval — re-approve". Any other exit → report what it says, next plan.
- `EXECUTING` `PENDING` `DONE` `FAILED` `SKIP` `MISSING` → skip (mention EXECUTING/FAILED, stay quiet on the rest).

Stale check, for each plan that is RUNNABLE and VALID, before anything else is done for it:
- If the plan's source is `mcp` (`${CLAUDE_PLUGIN_ROOT}/scripts/plan-state.sh get <plan> fingerprint_source`),
  first run `${CLAUDE_PLUGIN_ROOT}/jira/scripts/jira-context.sh mcp-request <KEY> --for check`. It prints one
  JSON line `{"tool":…,"args":{…}}`; call that tool once with those args. (If MCP is not available,
  skip both: the check below then gives UNCHECKED. A plan made over MCP is never checked over REST.)
  A plan whose source is `rest` is checked over REST as always, whatever `<TRANSPORT>` is.
- Then run
`${CLAUDE_PLUGIN_ROOT}/jira/scripts/jira-context.sh check <plan>`. It prints one verdict line, never ticket
text. Never run a plan unless it is RUNNABLE, VALID and FRESH.
- `jira-context.sh check` `FRESH` (exit 0) → implement it (steps below).
- `jira-context.sh check` `STALE <summary>` (exit 17) → the plan is now `stale` and its `.prev` and `changes.md` exist. Do not
  run it. Report "<KEY>: ticket changed since approval — <summary>", adding the `branch: <name>` line if
  the check printed one (work was already done on it). Queue the plan for Phase B (under `--execute-only`
  it stays `stale` on disk and the next planning run re-plans it).
- `jira-context.sh check` `UNCHECKED <reason>` (exit 21) → do not run it; report "<KEY>: not run — <reason>". The plan is untouched.
- `jira-context.sh check` exit 2 → do not run it; relay the message. A plan with no fingerprint (approved before 1.4.0, or not
  a Jira plan) is reported as "<KEY>: no ticket fingerprint — re-plan".

To implement a plan that is RUNNABLE, VALID and FRESH (KEY = its `ticket` field, read with `plan-state.sh get <plan> ticket`):
0. Read the slice: `${CLAUDE_PLUGIN_ROOT}/scripts/plan-state.sh slice <plan>` prints `SLICE <k>/<n> tasks <list|all>`. Keep `<k>` and `<n>`.
   `<ID>` is `<KEY>` when `<k>` is 1, and `<KEY>-s<k>` when `<k>` > 1: it names the review report, `plans/pr-review-<ID>.md`.
   A plan with no slices section is `1/1`, exactly as before. One run does ONE slice per plan: one branch, one PR.
1. `${CLAUDE_PLUGIN_ROOT}/jira/scripts/run-state.sh start-branch <plan> "<summary>"` → prints the branch: keep it as `<BRANCH>`.
   - A plan with no branch yet gets a new `feature/<KEY>-<slug>` (`feature/<KEY>-<slug>-s<k>` for slice 2 and later) off an up-to-date
     `<TARGET_BRANCH>`, recorded in the plan. A plan whose earlier run crashed resumes on the
     branch it recorded, with that run's work.
   - `start-branch` exit 12 (uncommitted changes outside the plan's own branch) → STOP Phase A and report it.
   - `start-branch` exit 13 (the branch exists but this plan didn't create it) or 14 (the plan's branch is gone)
     → report what it says, next plan. Never delete, reset or reuse a branch yourself.
   - `start-branch` exit 15 (progress logged on a gone or cleared branch) → report it, next plan. The plan needs
     a re-stamp and my re-approval; never clear its log or branch yourself.
   - `start-branch`, any other non-zero exit (2 refusal, 1 git failure) → report what it says, next plan.
2. Move the ticket to In Progress (see "Jira writes over MCP" below for the `mcp` form):
   `${CLAUDE_PLUGIN_ROOT}/jira/scripts/jira-transition.sh <KEY> :in-progress`
3. Run `/asdlc:implement-prd <plan> --execute` (Skill tool). It re-runs the gate and itself sets the
   plan to `executing`; you don't set it. It runs only the current slice's tasks and leaves the plan `executing`
   (you set `waiting` or `done` in step 6, once the PR exists). On a resumed plan it skips the tasks its Progress
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
   touched, or the ticket is Epic/Story/large). Run `/asdlc:review-pr <BRANCH> <TARGET_BRANCH> --id <KEY>` (for slice 2 and later, `--id <KEY>-s<k>`, i.e. `--id <ID>`),
   appending ` --council` when the mode is `council`. (`--id` names the report `plans/pr-review-<ID>.md`.)
   - REQUEST_CHANGES → executor fixes on the SAME plan (max 2 cycles), commit, push, re-run the review.
   - APPROVE → the reviewer brief first, then the AI summary. The brief must be the FIRST PR comment: nothing
     earlier in this run posts a comment on the PR. Never Read the brief or the diff; pass them as paths only.
     1. Diff file: `${CLAUDE_PLUGIN_ROOT}/scripts/review-brief.sh diff <KEY> origin/<TARGET_BRANCH> <BRANCH>`. On a resumed plan
        that already has a human-review record, add `--since <sha>` with the sha from
        `${CLAUDE_PLUGIN_ROOT}/jira/scripts/review-record.sh last <KEY> <PR_ID>` (nothing printed = no record, no `--since`).
        It prints the path and counts, no diff text.
     2. Run the `review-brief` agent with only these paths: the plan, `./plans/<KEY>/context.md`, `./plans/pr-review-<ID>.md`
        (it may be missing), `./plans/<KEY>/review.diff` and, with `--since`, that sha. Then
        `${CLAUDE_PLUGIN_ROOT}/scripts/review-brief.sh check <KEY>` (add `--rereview` when you used `--since`). It prints counts, never the brief.
        Exit 2 → run the agent once more, then check again; still exit 2 → report "<KEY>: reviewer brief invalid — not posted" and post nothing.
     3. (confirm) post the brief: `${CLAUDE_PLUGIN_ROOT}/jira/scripts/bb-pr-comment.sh <PR_ID> --file plans/<KEY>/review-brief.md`.
     4. (confirm) post the AI summary. It is an AI review, not a human one, and it says so:
        `${CLAUDE_PLUGIN_ROOT}/jira/scripts/bb-pr-comment.sh <PR_ID> "[asdlc] AI review (not a human review): <summary>"`.
     (`bb-pr-comment.sh` refuses text that does not start with `[asdlc] `.) Never run `review-record.sh add`: only my own
     `/asdlc:review-tour` records a human review.
6. Status: if `<k>` < `<n>`, `${CLAUDE_PLUGIN_ROOT}/scripts/plan-state.sh set <plan> status waiting` (the PR is recorded, and the
   next slice waits for its merge), and do NOT set `done`. Otherwise (the last slice, or no slices)
   `${CLAUDE_PLUGIN_ROOT}/scripts/plan-state.sh set <plan> status done`.
   Get the tier: `${CLAUDE_PLUGIN_ROOT}/scripts/review-report.sh must-read plans/pr-review-<ID>.md --diff origin/<TARGET_BRANCH> <BRANCH>`
   prints one JSON line (`tier`, `reasons`; it never prints the report's own wording; exit 3 means tier high). No report → tier `unknown`.
   Report: `<KEY> — <PR_URL> — AI-approved, awaiting your human review (tier <t>: <reasons>)`, with `<reasons>` the
   comma-joined `reasons` (or `none`). For tier `high`, add: "suggest a teammate's approval on Bitbucket too".
   When `<n>` > 1 add ` — slice <k> of <n>`; for `<k>` < `<n>` also "next slice starts in a later run, after this PR is merged".
   The ticket moves to Testing on MERGE (Jira automation), not here.

## Phase B — plan new tickets   (skip if --execute-only)
- Fetch tickets, where `<selection>` is the arguments with the phase flags removed. (No selection →
  my `STATUS_DEFAULT` tickets in `JIRA_PROJECT_KEY`.)
  - `rest`: `${CLAUDE_PLUGIN_ROOT}/jira/scripts/jira-mine.sh <selection>`.
  - `mcp`: `${CLAUDE_PLUGIN_ROOT}/jira/scripts/jira-mine.sh --mcp-args <selection>` prints one
    `{"tool":…,"args":{…}}` line; call that tool once with those args, then run
    `${CLAUDE_PLUGIN_ROOT}/jira/scripts/jira-mine.sh --from-mcp <selection>` (the same selection). It
    prints the same JSON list as the `rest` form, and warns on stderr about a second page or an empty
    result (relay the warning).
- The work list is every plan that is STALE (from Phase A, or any `./plans/*.plan.md` for which
  `plan-state.sh check` prints `STALE`), whatever the selection says, plus each jira-mine ticket
  whose plan file `./plans/<KEY>.plan.md` does NOT exist.
- For EACH key on the work list:
  1. Fetch the ticket → `./plans/<KEY>/context.md` (the script prints the path and counts, no ticket
     text). A STALE plan is moved to `.prev` and its `changes.md` kept. Exit 2 → skip it quietly: a
     plan that is not STALE already exists. Any other failure → report it, next key.
     - `rest`: `${CLAUDE_PLUGIN_ROOT}/jira/scripts/jira-context.sh fetch <KEY>`.
     - `mcp`: run `${CLAUDE_PLUGIN_ROOT}/jira/scripts/jira-context.sh mcp-request <KEY> --for fetch`,
       call the tool it prints once with those args. The receipt names the ticket's parent when there
       is one, with the exact args for it: make that one call too (only then). Then run
       `${CLAUDE_PLUGIN_ROOT}/jira/scripts/jira-context.sh fetch <KEY> --source mcp`.
       Exit 3 (the comment thread was cut off by the connector) → run the plain REST fetch
       `${CLAUDE_PLUGIN_ROOT}/jira/scripts/jira-context.sh fetch <KEY>` instead. Exit 1 (for example
       a capture that was rejected or has expired) → report it, next key; a retry needs a new request.
  2. Run `/asdlc:implement-prd ./plans/<KEY>/context.md --plan-only` (Skill tool; writes + stamps
     ./plans/<KEY>.plan.md, then stops; on a re-plan it reuses the `.prev` answers and handles `changes.md`)
  3. Report: `<KEY> planned — answer open questions, then /asdlc:plan approve <KEY>`
     (a re-plan: `<KEY> re-planned after ticket change — ...`).
- A plan that is not STALE is left alone, whatever its status — planning never clobbers an approval.
- Never read `./plans/<KEY>/raw/`, `context.md`, `changes.md`, `review-brief.md` or `review.diff` yourself: ticket text is for the
  planner, critic and brief writer. Report from what the scripts print (counts, verdict lines) only.

## Jira writes over MCP
Only when `<TRANSPORT>` is `mcp`; under `rest` the plain scripts (`jira-transition.sh <KEY> <target>`,
`jira-notify.sh <KEY> [note]`) do the writes, as before. Same rule as above: use the printed args
unchanged, never read raw output.
- Transition (may run automatically, like the REST form):
  1. `${CLAUDE_PLUGIN_ROOT}/jira/scripts/jira-transition.sh --mcp-args <KEY>` prints two
     `{"tool":…,"args":{…}}` lines. Call each tool once with its args (the first reads the status, the
     second the available transitions; the hook shows you receipts only).
  2. `${CLAUDE_PLUGIN_ROOT}/jira/scripts/jira-transition.sh --from-mcp <KEY> <target>` (same target as the
     REST form, `:in-progress` and the other aliases included) prints one of:
     - `ALREADY "<status>"` → nothing to do.
     - `TRANSITION <id>` and a `{"tool":…,"args":{…}}` line → call that tool once with those args.
     - the available transitions on stderr and exit 1 → report it, as for the REST form.
  3. If MCP is not available, or a call fails, run the REST form `jira-transition.sh <KEY> <target>`
     instead (it checks the status first, so it is safe to repeat). Say so only if that fails too.
- Comment with a mention (a Jira write to other people: only when I ask for it, and I confirm the call):
  1. `${CLAUDE_PLUGIN_ROOT}/jira/scripts/jira-notify.sh --adf <KEY> ["note"]` makes no network call. It
     opens a comment request and prints the ADF comment body on stdout (its stderr line shows the
     tool and `cloudId`). Call `addCommentToJiraIssue` with `{cloudId, issueIdOrKey, contentFormat: "adf",
     commentBody: <that JSON, as a string>}`. This tool is never pre-approved: I am asked each time. The
     plugin blocks an edit of an existing comment, `editJiraIssue`, and a body that does not start with the
     pipeline marker, while the request is open.
  2. Then run `${CLAUDE_PLUGIN_ROOT}/jira/scripts/jira-notify.sh --from-mcp <KEY>`; it prints `COMMENT <id>`.
     Keep the id and never post a second comment for the same step.
  3. Watchers have no MCP tool: run `${CLAUDE_PLUGIN_ROOT}/jira/scripts/jira-notify.sh --watchers <KEY>`
     (REST when a Jira login is ready, otherwise it says "watchers skipped": relay that).
  4. If the `addCommentToJiraIssue` tool is not in your tools, run the REST form
     `jira-notify.sh <KEY> ["note"]` instead. If the call FAILED or was blocked, do NOT fall back: the comment may
     already be posted. Tell me what happened and ask me what to do.

## Standing authorization (this run)
- Moving a ticket to In Progress (`:in-progress`) may happen automatically.
- On REQUEST_CHANGES you MAY re-run the executor on the same plan automatically, up to 2 cycles, then escalate.
- The plugin pre-approves no commit, push or Bitbucket write. You MUST pause and show me the exact
  command before every commit, push and Bitbucket write (open PR, post comment), then wait for my go.
  The harness also prompts for them unless my own permission settings allow them.
- `${CLAUDE_PLUGIN_ROOT}/jira/scripts/run-state.sh force-unlock` is mine alone: never run it unless I tell you to.
- Plan approval is NEVER yours to give — Phase A only runs plans that already check RUNNABLE and validate VALID.

## Report
Finish with a summary. Always start with the review queue lines from `review-queue.sh` (`QUEUE <waiting>/<max>` and each
waiting PR), run again at the end of Phase A so it includes the PRs this run opened (under `--plan-only`, run it once for the report). Then: executed (with PR links), newly planned (awaiting approval), skipped
(edited / stale / unchecked / invalid / executing / blocked / waiting for a slice PR to merge). If both phases did nothing, say so. Then release the lock:
`${CLAUDE_PLUGIN_ROOT}/jira/scripts/run-state.sh unlock <RUN_ID>`.
