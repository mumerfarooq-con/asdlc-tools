---
description: Walk me through the riskiest hunks of a PR, one question each, and record only what I answered
argument-hint: <PR id | PR URL | KEY>
disable-model-invocation: true
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/jira/scripts/jira-conf.sh:*), Bash(${CLAUDE_PLUGIN_ROOT}/scripts/plan-state.sh get:*), Bash(${CLAUDE_PLUGIN_ROOT}/scripts/review-report.sh:*), Bash(${CLAUDE_PLUGIN_ROOT}/jira/scripts/review-record.sh last:*), Bash(${CLAUDE_PLUGIN_ROOT}/scripts/tour-git.sh:*), Read, Glob, Grep
---

# /asdlc:review-tour

Arguments: $ARGUMENTS

A guided read of the code that must be read by a human. The point is that I form my own view of
each hunk, so you ask and I answer. Run from the repo root. You never edit code or plan files.
Run one command per Bash call, only the commands allowed above (no `;`, `&&`, pipes, `ls` or `cat`):
anything else stops me with a permission prompt. All git goes through `${CLAUDE_PLUGIN_ROOT}/scripts/tour-git.sh` (below); never run bare `git`. Use Glob and Read for the plans and the report.

## 1. Resolve the PR
- A Bitbucket PR id or URL: match the URL's workspace and repo against `BB_WORKSPACE` and `BB_REPO`
  from `${CLAUDE_PLUGIN_ROOT}/jira/scripts/jira-conf.sh` (a mismatch means local-only, below). Find the
  plan in `./plans/*.plan.md` whose `${CLAUDE_PLUGIN_ROOT}/scripts/plan-state.sh get <plan> pr` ends in `/pull-requests/<id>`.
  If more than one plan claims it, STOP and say so.
- A ticket KEY: use `./plans/<KEY>.plan.md` and its `pr` and `branch`.
- A GitHub URL or a branch name: **local-only**. The record is written locally and never posted. A record
  needs a plan KEY (find the plan whose `branch` is that branch); use the GitHub PR number, or `0` for a
  branch with no PR. No plan: the tour still runs, but records nothing, and you say so at the start.
- No match, or no `branch`: say so and STOP. Refuse a branch starting with `-`.
- Run `${CLAUDE_PLUGIN_ROOT}/scripts/tour-git.sh fetch <branch>`, then `${CLAUDE_PLUGIN_ROOT}/scripts/tour-git.sh head <branch>` for the head (sha40).
- The report id `<ID>`: read `${CLAUDE_PLUGIN_ROOT}/scripts/plan-state.sh get <plan> slice`. Empty or `1`: `<ID>` is `<KEY>`;
  otherwise `<KEY>-s<k>`. (A branch with no plan: its slug.) The record below still uses `<KEY>`.

## 2. Build the hunk list (at most 5)
- Run `${CLAUDE_PLUGIN_ROOT}/scripts/review-report.sh must-read plans/pr-review-<ID>.md --diff origin/<TARGET_BRANCH> origin/<branch>`
  (`TARGET_BRANCH` from the config, else the repo's default branch). Use its `rows`; say the risk tier.
- Exit 3 (no usable rows, it fails closed): pick at most 5 hunks yourself from the diff, aimed at
  migrations, authz, irreversible operations, billing, infra, concurrency, the FE/API contract and
  env config. Label them "picked by the tour".
- Re-review: if `${CLAUDE_PLUGIN_ROOT}/jira/scripts/review-record.sh last <KEY> <PR>` prints a sha,
  keep only the hunks in files that `${CLAUDE_PLUGIN_ROOT}/scripts/tour-git.sh changed <last> <branch>` lists. None left: say so and STOP.
- Hunk lines are in the head version. If a row's range no longer matches the file, print the head version (step 3.1),
  re-locate the hunk, and say you did.

## 3. Each hunk, one at a time
1. Show the code at the head, not the working tree (my checkout may be on another branch):
   `${CLAUDE_PLUGIN_ROOT}/scripts/tour-git.sh show <branch> <path>` prints the head version with line numbers;
   show the lines around the range. Then `${CLAUDE_PLUGIN_ROOT}/scripts/tour-git.sh diff <TARGET_BRANCH> <branch> <path>`. Do not read out
   the report's "why" text; I form my own view first.
2. Ask ONE question about behaviour ("the poll closes mid-vote: what happens to a vote in flight?"),
   never "is this right?".
3. **STOP and wait for my answer.** Do not show the next hunk, and do not answer for me, until I have answered.
4. Check my answer against the code and cite `file:line`: "matches the code", "partly: <file:line>" or
   "doesn't match: <file:line shows ...>".
5. If I say "skip", that hunk is not reviewed.
6. A reply that is not an answer ("ok", "next", "go on", "?") is not one: ask once whether I mean an
   answer or a skip, and do not check it until I say.

## 4. The record
- List the hunks I answered and every mismatch.
- Show the exact command and run it only after I confirm:
  `${CLAUDE_PLUGIN_ROOT}/jira/scripts/review-record.sh add <KEY> <PR> <sha40> <answered hunks>`
  Build each hunk from the report's JSON row as `<file>:<start>-<end>`, never from the report's text;
  a hunk picked by the tour uses its own file and head-version line range, in the same form
  (no answered hunks: record nothing and say so).
- Bitbucket PR: then show, and run only after I confirm:
  `${CLAUDE_PLUGIN_ROOT}/jira/scripts/bb-pr-comment.sh <PR_ID> --record --file <path add printed>`
- GitHub or a local branch: stop after the local record.

## Rules
- Never record a hunk the user did not answer.
- Never answer for me. Never approve, decline or merge the PR. Never post anything else.
- Never post or record without my confirmation.
- Aim for about 15 minutes: at most 5 hunks.
