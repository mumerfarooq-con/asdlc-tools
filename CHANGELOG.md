# Changelog

All notable changes to the `asdlc` plugin are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the plugin adheres to [Semantic Versioning](https://semver.org/).

Every PR that changes plugin content (commands, agents, PDQC assets) must bump the version and add an entry here — `/plugin update` delivers changes reliably only when the version moves.

## [1.7.0] - 2026-11-03

Groundwork for the ticket check (M4b). Plans, approvals and fingerprints are unchanged.

### Added

- **`plan-state.sh log <plan> <task> <ROLE> <VERDICT> [note]`** writes a progress line. It accepts only the six contract verdicts (`EXECUTOR DONE`, `EXECUTOR BLOCKED`, `REVIEW APPROVED`, `REVIEW CHANGES_REQUESTED`, `TEST PASS`, `TEST FAIL`), changes only the Progress part (the approval hash stays valid), and caps the note at 300 bytes without splitting a character.
- **`plan-state.sh report-id <plan>`** prints the review report id (`<KEY>`, or `<KEY>-s<k>` from slice 2). `jira-run`, the review queue and `/asdlc:review-tour` all use it.
- **`plan-state.sh find-branch <branch>` and `find-pr <id>`** print the one plan that claims a branch or a Bitbucket PR, read-only. Exit 1 means none, exit 2 means more than one, or a bad argument. `/asdlc:review-tour` uses them instead of searching the plans.
- **`jira-context.sh meta <KEY>`** prints the saved ticket's issue type and labels (a safe character set, no leading `-`, at most 200 bytes) for `review-mode.sh`, so the council/solo choice uses them under `--execute-only` too. If `review-mode.sh` fails, `jira-run` runs the council.
- **`docs/plan-only-flow.md`**: the plan-only flow, in one file that `/asdlc:implement-prd --plan-only` and `/asdlc:jira-run` both follow.
- **"Capture protocol"** section in the Jira guide: the MCP request schema, the capture envelope, the receipts, the TTL and who opens and consumes each request.

### Changed

- **Progress lines are written by the orchestrator through `plan-state.sh log`.** `prd-executor`, `prd-reviewer` and `prd-tester` return their verdict line and no longer edit a stamped plan. In a plan that is not stamped (the default `/asdlc:implement-prd` pipeline), the executor and the tester still update the task in place. `prd-reviewer` writes only its own retrospective review file.
- **MCP requests share one library** (`jira/scripts/mcp-lib.sh`): one 10-minute expiry, a `kind` field in every request, and one hook path for the search and Bitbucket captures. A hygiene test checks that every script a receipt names exists.
- **Shared review helpers** live in `jira/scripts/review-lib.sh`: the key and directory checks, the `plans/` symlink walk, the PR id from a URL, and one hunk grammar for the report and the record. A record hunk with a `.` path part is now refused, as the report already did.
- **`/asdlc:jira-run` Phase A has named sections** (Review queue, Which plans run, Stale check, Run a plan, After APPROVE), and its MCP variants are in one "Jira over MCP" section.
- **Searching on newer Claude Code builds.** The main session there has no Glob or Grep tools. Commands no longer rely on them, and the `pr-reviewer*` agents search with `grep -rn` or `find` through Bash. Agents that declare Glob and Grep still get them, so no agent's tools changed. No plugin file pre-approves `rg` or `find`.

### Upgrading

- Nothing to do for plans and approvals: hashes and fingerprints are unchanged.
- A custom agent that appends Progress lines itself should return its verdict instead. The orchestrator logs it with `plan-state.sh log`.
- After `/asdlc:jira-run`'s first confirmation pause, your Claude Code may ask again for scripts the command pre-approves. Approve them, or add them to your own settings (see the Jira guide).

## [1.6.0] - 2026-11-02

### Added

- **Review queue and cap.** `jira/scripts/review-queue.sh` counts the PRs the plugin opened (plans with a recorded Bitbucket `pr`) that still wait for a human: open, no human-review record at the current head, no approval from someone other than the author. `REVIEW_QUEUE_MAX` in `.asdlc/jira.conf` (default 3, `0` turns the cap off) caps them: at or over it the script exits 18, and `/asdlc:jira-run` executes nothing that run (plans stay approved) while Phase B still plans. The queue is checked before the first branch and after every PR a run opens, and every run prints it. If Bitbucket and git cannot tell a PR's state, it counts as waiting. The Bitbucket response shapes it reads are the documented ones and are not yet verified against a live workspace.
- **"Human must read" in every review report.** The chair's report and the solo reviewer's gain a risk tier (`high`, `normal`, `skim`) and at most 5 hunks, each with a reason from a fixed list. `scripts/review-report.sh must-read <report> [--diff <base> <head>]` reads it as JSON, never prints the free text, and fails closed (exit 3, tier `high`). A `skim` claim is checked against the changed paths. `review-pr` gains `--id <name>`, so the report is `plans/pr-review-<name>.md`.
- **Reviewer brief.** A read-only `review-brief` agent writes `plans/<KEY>/review-brief.md`: intent, which tests assert what the ticket asked, the must-read hunks, deviations from the plan, a reading order and three checks for a dev environment. `scripts/review-brief.sh` writes the diff (`diff`) and validates the brief (`check`, counts only). `/asdlc:jira-run` posts the brief as the first PR comment after an AI approval, then the AI summary, each after you confirm, and never reads either.
- **`/asdlc:review-tour <PR id | PR URL | KEY>`.** Walks you through the must-read hunks one at a time with one behaviour question each, waits for your answer, checks it against the code, and records only the hunks you answered (`plans/<KEY>/human-review.jsonl`, and with your confirmation a `[asdlc] Human review:` comment on a Bitbucket PR). A GitHub PR or a local branch keeps the record local. After new commits, only the changes since your last reviewed commit are covered. `scripts/review-record.sh` stores and parses the record. All of the tour's git goes through `scripts/tour-git.sh`, a read-only wrapper with fixed forms (`fetch`, `head`, `show`, `diff`, `changed`) that checks every ref and path, so the tour pre-approves no bare `git` command. On a slice 2 or 3 PR it reads that slice's report. The record is an honesty aid, not a security control: a model could forge it.
- **PR slices.** A plan may group its tasks into at most 3 sequential slices under `## PR slices` (migrations first). `plan-state.sh validate` checks them and `plan-state.sh slice` prints the current one. `/asdlc:jira-run` runs one slice per branch (`feature/<KEY>-<slug>-s<k>` from slice 2) and PR, and `run-state.sh next-slice` moves on only when Bitbucket REST says the previous PR is MERGED (exit 19 otherwise). A new `waiting` status (`check` prints `WAITING`, exit 21) marks a plan whose slice PR is open with slices remaining. One approval covers every slice.

### Changed

- **Every PR comment the plugin posts starts with `[asdlc] `**, and `bb-pr-comment.sh` refuses (exit 2) text that does not. The AI summary starts `[asdlc] AI review (not a human review):`, the brief `[asdlc] Reviewer brief`. A `[asdlc] Human review:` comment is refused unless `--record` is given, which only `/asdlc:review-tour` passes. `bb-pr-comment.sh --file <path under plans/>` posts a file's text without printing it.
- `/asdlc:jira-run` ends each PR with `<KEY> — <PR_URL> — AI-approved, awaiting your human review (tier <t>: <reasons>)`, passes `--id` to `review-pr`, and sets a plan to `waiting` (more slices) or `done` (last slice) after the PR exists.
- `run-state.sh next-slice` is the second scripted path back to `approved`, next to `reset-executing`. Both use one compare-and-set on the hash you approved, and a hygiene test names them so a third writer fails the suite. Nothing but `/asdlc:plan approve` creates an approval.
- **The gates refuse test modes.** `run-state.sh next-slice`, `review-queue.sh` and `bb-pr-comment.sh` refuse `--fixtures`, `ASDLC_FIXTURES` and `--conf` (exit 2) unless `ASDLC_TEST_FIXTURE_CHECK=1`, as `jira-context.sh check` already did for fixtures. `next-slice` also requires the merged PR's source branch to be the plan's branch.
- `review-brief.sh check` refuses a brief that contains a secret-like token (a private-key header, `AKIA`, `ghp_`, `github_pat_`, `xox?-`, `ATATT`) and prints only the count. The skim check counts a rename by both its paths, and a hunk path with a comma or a space fails closed.
- The queue lists origin once per run and treats a PR whose branch is gone as closed, since PRs are opened with `close_source_branch`. A PR whose branch was deleted while it is still open on Bitbucket therefore leaves the queue.

### Upgrading

- Open PRs that earlier versions opened count toward the queue from the first run, if their plan still records a `pr`. With 3 or more waiting, the first run executes nothing: review them with `/asdlc:review-tour <PR>`, or set `REVIEW_QUEUE_MAX=0` in `.asdlc/jira.conf` to turn the cap off.
- Every plugin PR comment now starts with `[asdlc] ` and `bb-pr-comment.sh` refuses others. Update any script of your own that calls it.
- `run-state.sh next-slice` needs a Bitbucket token, because a merge is never inferred from git. The queue works from git alone but is better with one: it is the only way to see a teammate's approval or a record posted elsewhere.
- Your own scripts that call `run-state.sh next-slice`, `review-queue.sh` or `bb-pr-comment.sh` with `--fixtures` or `--conf` must export `ASDLC_TEST_FIXTURE_CHECK=1`.
- Plans without `## PR slices` work exactly as before, and plans stamped under 1.5.0 stay valid.

## [1.5.0] - 2026-10-23

### Added

- **Jira over the Atlassian MCP connector, with the token as fallback.** `JIRA_TRANSPORT` in `.asdlc/jira.conf` is `auto` (default: MCP when connected, else REST), `mcp` or `rest`. The connector's server name defaults to `claude_ai_Atlassian`; set `ASDLC_JIRA_MCP_SERVER` in your shell for another. Ticket fetch, the stale check, ticket search, transitions and comments all work over MCP, and no Jira token is needed. MCP cannot download images, add watchers, list sprints or validate status names, and cuts off very long comment threads; `jira-setup.sh check` warns about each. A plan built over MCP records `fingerprint_source: mcp` and is checked only over MCP (otherwise `UNCHECKED`: connect the connector or re-plan). The REST fingerprints are unchanged.
- **Capture hook** (`hooks/hooks.json`, `hooks/mcp-capture.sh`). While a script has opened a request, the response of the matching MCP call is stored under `plans/` and the model sees only a receipt, so ticket text stays out of the orchestrator's context. It does nothing otherwise, expires a request after 10 minutes, and blocks an unmarked comment or an edit while a request is open. It is registered for the Jira tools and for MCP servers whose name contains `bitbucket`; no other server's calls reach it.
- **Bitbucket MCP seam.** `BB_TRANSPORT` (`rest`, the default, or `mcp`) with `ASDLC_BB_MCP_SERVER` and `ASDLC_BB_MCP_PROFILE`. No real profile ships yet, so REST stays the way to reach Bitbucket.
- `jira-context.sh transport` prints the transport in effect.

### Changed

- Plan and execute a ticket with the same account, which now includes the account signed in to the MCP connector.
- `jira-run` pre-approves the read and transition tools of the default connector name only. Comments (always marker-first), edits and ticket creation stay confirmed by you.
- Internal: the list of fingerprint sources and the ticket-context code are shared between fetch and check.

## [1.4.0] - 2026-10-22

### Added

- **Full ticket context.** `jira/scripts/jira-context.sh fetch <KEY>` (Jira REST v2) writes `plans/<KEY>/context.md`, the planner's PRD for a ticket: the description, all human comments (newest first, paged), the parent ticket, one level of linked tickets (with a pointer to their own plans), image attachments and Figma links. `raw/` keeps the Jira responses and `build` turns them into `context.md`, so another source can be added later. Its output names only the file and counts, never ticket text.
  - Images: png, jpeg, gif and webp only, checked by their first bytes; `MAX_IMAGES` (default 10, `0` turns downloads off) and `MAX_IMAGE_MB` (default 5). Downloads follow redirects over https only and never send the token to another host.
  - Pipeline comments (starting with `PIPELINE_COMMENT_MARKER`, also in the wiki-escaped form `\[asdlc\]`) are left out. An empty or blank marker is refused. Start any Jira automation comment with the marker.
  - Every Jira GET now has a 60 second limit, and a 429 gets a hint.
- **Ticket fingerprint.** `build` hashes what a person would re-read (title, description, human comments, parent key, links, attachment ids; not status, assignee, sprint, rank or timestamps) into `plans/<KEY>/fingerprint`. `stamp` copies `ticket_fingerprint`, `fingerprint_at` and `fingerprint_source` into the plan header, outside the plan hash. `plan-state.sh set` refuses these fields.
- **Stale check.** `jira-context.sh check <plan>` fetches the ticket again (GETs only) and prints `FRESH` (exit 0), `STALE <summary>` (exit 17) or `UNCHECKED <reason>` (exit 21); exit 2 means it refused (not runnable, not a Jira plan, no fingerprint). A STALE plan is set to `stale`, copied to `.plan.prev.md`, and `plans/<KEY>/changes.md` lists the changes (comment ids, a description diff of at most 200 lines, parent, links, attachments). `/asdlc:jira-run` Phase A runs it before each approved plan; Phase B re-plans every STALE plan in the same run, even outside `--key`/`--sprint`, and the planner and critic read `changes.md`. A plan that `--reset-executing` restored gets the same check, and the report names its recorded branch. Plan and execute a ticket with the same Jira account: restricted comments differ by account and would give a false STALE.
- `scripts/plan-approve.sh`: approval, split out of `plan-state.sh` (shared helpers are in `scripts/plan-lib.sh`). Same behaviour and exit codes, reached only through `/asdlc:plan approve`, never pre-approved.
- `jira-setup.sh check` validates `MAX_IMAGES`, `MAX_IMAGE_MB` (whole numbers) and a non-empty marker.

### Changed

- **`plan-state.sh approve` is removed**; use `/asdlc:plan approve` (it calls `plan-approve.sh`).
- **`approve` refuses a STALE plan** (it used to allow it). Re-plan instead.
- **Plans approved under 1.3.x have no fingerprint.** `/asdlc:jira-run` Phase A reports them as "re-plan" and does not run them: re-plan them first. Plans without a Jira ticket have none either. Standalone `/asdlc:implement-prd --execute` still runs them, and warns when a plan does have a fingerprint, because no stale check ran.
- `ticket-to-prd.sh` is deprecated: `/asdlc:jira-run` no longer uses it (it is no longer in its pre-approved tools); scheduled for removal in 2.0.0. It now prints a one-line deprecation note on stderr.
- `jira-mine.sh` no longer requests or prints ticket descriptions, so ticket text stays out of the run's own context.
- The planner, `plan-critic` and the plan template cover the new context: comments followed, parent and linked tickets, images, access rules, and what changed since the previous plan.

## [1.3.1] - 2026-10-22

### Changed

- **README rewritten.** Every command is covered, including `/asdlc:jira-run`, `/asdlc:jira-setup` and `/asdlc:plan`. New sections cover requirements, a quick start per workflow, how approval works, the subagents and troubleshooting.
- **Install instructions for the Claude desktop app.**
  - The Code tab shares the Claude Code install.
  - Customize → Plugins needs the repository added as a marketplace first, because ASDLC isn't in Anthropic's directory.
  - There is an HTTPS fallback for clone errors.
- **Plugin listing.** `plugin.json` gains `displayName`, a clearer description, `homepage`, `repository`, `license` and `keywords`. The marketplace descriptions now mention the Jira leg. A plugin-level `README.md` describes the commands and what data the plugin sends.

## [1.3.0] - 2026-10-21

### Added

- **Plan format and planner protocol.** `/asdlc:implement-prd --plan-only` (and so `/asdlc:jira-run` planning) now follows a fixed flow: terms, impact scan, plan from `templates/plan.md`, critic, revise, validate, stamp. The plan has Goal, Context used, What else uses this, Must still work, Changes (executor-ready tasks), Tests, Risk, Open questions and Critic notes. The planner is given rules for hypotheses, access, and unknowns (which become open questions). The default pipeline mode keeps its old plan format.
- `scripts/impact-scan.sh`: searches the repo and `IMPACT_EXTRA_PATHS` for the plan's terms and writes `plans/<ID>/impact.md`, with sensitive-path and sensitive-topic markers. Two passes at most. It also copies the plan template to `plans/<ID>/plan-template.md`, so the planner never reads the plugin dir.
  - Secret files are never searched, in any root and whatever `IMPACT_EXCLUDE` says: `.env*`, `*.pem`, `*.key`, `*.p12`, `*.pfx`, `*.jks`, `*.keystore`, SSH keys (`id_rsa*` and the like), `.netrc`, `.npmrc`, `.pypirc`, `.git-credentials`, `.pgpass`, `*.tfvars` (a directory with such a name is skipped too). Their lines would otherwise be copied into impact.md.
  - `plans`, `prds` and `.asdlc` are skipped only at the root being searched, so code in `src/plans/` is found. `IMPACT_EXCLUDE` entries still match at any depth.
  - A failed search (for example an unreadable `IMPACT_EXTRA_PATHS` root) stops the scan with exit 2 and writes no impact.md, instead of reading as `(0 hits)`.
- `plan-critic` agent (Opus, read-only): reviews a plan in a fresh context and returns findings as Critic notes rows.
- `plan-state.sh validate | approve | replan | progress`. `validate` checks that a plan is complete (required sections, no open questions, no unanswered critic blockers). `approve` validates, re-hashes and approves. `replan` moves the plan to `.prev`. `progress` prints the latest log entry per task. Every subcommand also takes a bare plan id. New check words `NEEDS_INFO` and `BLOCKED`.
  - `validate` fails closed on Critic notes rows: a row whose cell count differs from the header's (an unescaped `|`; write `\|`) makes the plan INVALID. Severity and the `disagree` / `human accepted:` response are compared case- and markup-insensitively (`**Blocker**`, `Blocker.`).
- `/asdlc:plan approve|replan|validate <ID>`: human-only (`disable-model-invocation`). `plan-state.sh approve` is in no command's pre-approved tools, so approving needs your confirmation.
- `prd-executor` stops with `EXECUTOR BLOCKED` when the approved plan can't work as written, instead of improvising.

### Changed

- `check` prints `EDITED` (exit 11) where it printed `STALE` for a plan whose approved part no longer matches its hash. `STALE` now means the ticket changed after approval (exit 17).
- Execute mode and `/asdlc:jira-run` Phase A require `check` = RUNNABLE and `validate` = VALID. **Plans written before 1.3.0 don't validate and are not executed: re-plan them** (`/asdlc:plan replan <ID>`, then plan again).
- Approval is `/asdlc:plan approve`, not hand-editing `status: approved`.
- The suggested `.gitignore` lines gain `plans/*/` (impact.md can quote code) and `plans/*.plan.prev.md` (an old plan), and `jira-setup.sh check` warns when they are missing. Add them to existing repos.

[1.5.0]: https://github.com/mumerfarooq-con/asdlc-tools/releases/tag/asdlc--v1.5.0
[1.4.0]: https://github.com/mumerfarooq-con/asdlc-tools/releases/tag/asdlc--v1.4.0
[1.3.1]: https://github.com/mumerfarooq-con/asdlc-tools/releases/tag/asdlc--v1.3.1
[1.3.0]: https://github.com/mumerfarooq-con/asdlc-tools/releases/tag/asdlc--v1.3.0

## [1.2.0] - 2026-10-13

### Added

- **Resumable Jira runs.** A stamped plan now has a Progress section after an `<!-- asdlc:progress -->` line, and the approval hash covers only the plan above that line. The executor, reviewer and tester log task status, notes and verdicts there instead of inside the tasks, so a run's own logging never voids the approval. After a crash, `--reset-executing` restores the approval and the next run resumes on the plan's branch, skipping tasks that already passed their tests. Plans stamped before this release keep their hashes until they gain a progress line, which then makes them STALE: they restart from scratch after a re-stamp and re-approval.
- `scripts/plan-state.sh`:
  - The hash is versioned: with a progress line it is the sha256 of `asdlc-plan-v2` plus the part above the line, so a line inserted into an approved plan can't hide text below it.
  - `stamp` owns the progress line and refuses a plan that already contains one. A re-stamp is a new approval and a new run, so it empties the Progress log.
- `jira/scripts/run-state.sh`:
  - `lock` / `unlock <run-id>` / `status` hold the run lock, which records which run holds it and since when.
  - `force-unlock` is human-only and never pre-approved.
  - `reset-executing` and `list` work across all plans.
  - `start-branch` exits 15 when a plan has logged progress but its branch is gone or was cleared (re-stamp and re-approve). A resumed branch must be `feature/<KEY>-*` for the plan's own ticket and not the target branch, and the branch is recorded before it is created.
  - `start-branch` creates `feature/<KEY>-<slug>` off an up-to-date target branch, or resumes the branch the plan recorded. It never reuses or resets a branch the plan didn't record, and it reduces the ticket summary to `[a-z0-9-]` before using it in the branch name.

### Changed

- `jira-transition.sh` does nothing and exits 0 when the ticket is already in the target status (compared case-insensitively), so a re-run doesn't fail on In Progress.
- `/asdlc:jira-run` pre-approves only `git status` and `git add`: the branch setup moved into `run-state.sh start-branch`, which runs fixed git commands.
- `prd-executor`, `prd-reviewer` and `prd-tester` write to the Progress section when a plan has one. Plans without it, such as those from the default `/asdlc:implement-prd` pipeline, are updated in place as before.

[1.2.0]: https://github.com/mumerfarooq-con/asdlc-tools/releases/tag/asdlc--v1.2.0

## [1.1.1] - 2026-10-13

First tagged release of the Jira leg (1.1.0 was merged but never tagged; its changes ship here).

### Changed

- `plan-state.sh` moved from `jira/scripts/` to the plugin's shared `scripts/`, since `/asdlc:implement-prd --plan-only` and `--execute` use it outside the Jira leg too. Commands reference the new path; nothing changes for anyone invoking the commands.
- `/asdlc:implement-prd --plan-only` names the plan by a neutral plan id (the ticket key in the PRD title if there is one, else the PRD basename) and hands `prd-planner` the exact output path, so the planner and the command can't disagree on where the plan goes.

[1.1.1]: https://github.com/mumerfarooq-con/asdlc-tools/releases/tag/asdlc--v1.1.1

## [1.1.0] - 2026-10-08

Merged to `main`, never tagged: first released as 1.1.1.

### Added

- **Jira leg** (`/asdlc:jira-run`, `/asdlc:jira-setup`): a two-phase run that executes approved plans (In Progress → `/asdlc:implement-prd --execute` → Bitbucket PR → `/asdlc:review-pr` solo or council by diff) and plans new tickets for file-based approval. Approval lives in the plan file's header block, bound to a sha256 of the plan body; a run lock serializes runs. The plugin pre-approves no commit, push or Bitbucket write: the command tells the agent to show each and wait for the user's go, and the harness prompts for them unless the user's own permission settings allow them. A run stages only the files the executor reports, never with `git add -A`. The ticket moves to Testing on merge via Jira automation.
- Jira/Bitbucket scripts under `jira/scripts/` (ticket search, ticket → PRD, plan state, transitions, notify, sprints, people, PR open/comment, review depth), all REST over `curl` + `jq`, bash 3.2 compatible.
- Per-project config `.asdlc/jira.conf` (`KEY=value`, parsed against an allowlist, never sourced) from `jira/templates/jira.conf`. Tokens stay in env vars (`JIRA_EMAIL`, `JIRA_TOKEN`, `BITBUCKET_TOKEN`). `/asdlc:jira-setup` pre-fills it from older in-repo env vars, checks tokens, makes test calls to Jira and Bitbucket, verifies workflow statuses, and creates `docs/access-rules.md` and `docs/known-traps.md` from templates.
- Fixture mode (`--fixtures <dir>`) on every Jira/Bitbucket script, and an offline test suite (`tests/jira/run.sh`) run in CI.
- `/asdlc:implement-prd --plan-only` (plan, stamp, stop for approval) and `--execute <plan>` (run only a plan that checks RUNNABLE). The default pipeline mode is unchanged apart from the foreground-subagent rule.

## [1.0.0] - 2026-07-24

First versioned release. Everything below shipped between the initial packaging and this tag.

### Added

- **Three workflow commands**: `/asdlc:implement-prd` (plan → execute → review → test pipeline from a PRD), `/asdlc:review-pr` (solo reviewer by default, 3-panelist council + chair with `--council`), and `/asdlc:pdqc` (codebase-scoped pre-delivery quality gate: 5 parallel inspectors + QA chair + triage rubric).
- **Fifteen subagents** in one plugin, so cross-workflow references (e.g. the review workflow delegating fixes to `prd-executor`) resolve without extra installs.
- **GitHub PR mode** for `/asdlc:review-pr` via the `gh` CLI (no MCP required), alongside the original Bitbucket MCP mode; provider auto-detected from the PR URL or the origin remote. Write actions on either provider remain approval-gated and comment-only.
- **Solo `pr-reviewer` agent** for the default (non-council) review mode.
- **Four PDQC stack profiles** — Django, FastAPI, Node/Express, React — as swappable detection heuristics with identical section structure; new stacks only need a sibling file.
- **Example reports** from real runs: PDQC against healthchecks (26 triaged findings, 2 evidence-verified blockers) and a council review of wagtail#14411.
- MIT license, CI validation on every PR and push, install/update/contribution docs.

### Changed

- Reviewer and executor personas are framework-agnostic: stack vocabulary (serializers, querysets, `develop` base branch) generalized; stack specifics live in the PDQC profiles and the target repo's own standards docs.
- PDQC ships no calibration data; seed checklists are generated per target repo with `pdqc/calibration/extract_seed_checklist.py` and referenced via `pdqc.config.yaml`.

[1.0.0]: https://github.com/mumerfarooq-con/asdlc-tools/releases/tag/asdlc--v1.0.0
