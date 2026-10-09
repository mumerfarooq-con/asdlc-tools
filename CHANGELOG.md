# Changelog

All notable changes to the `asdlc` plugin are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the plugin adheres to [Semantic Versioning](https://semver.org/).

Every PR that changes plugin content (commands, agents, PDQC assets) must bump the version and add an entry here — `/plugin update` delivers changes reliably only when the version moves.

## [1.1.0] - 2026-10-08

### Added

- **Jira leg** (`/asdlc:jira-run`, `/asdlc:jira-setup`): a two-phase run that executes approved plans (In Progress → `/asdlc:implement-prd --execute` → Bitbucket PR → `/asdlc:review-pr` solo or council by diff) and plans new tickets for file-based approval. Approval lives in the plan file's header block, bound to a sha256 of the plan body; a run lock serializes runs. The plugin pre-approves no commit, push or Bitbucket write: the command tells the agent to show each and wait for the user's go, and the harness prompts for them unless the user's own permission settings allow them. A run stages only the files the executor reports, never with `git add -A`. The ticket moves to Testing on merge via Jira automation.
- Jira/Bitbucket scripts under `jira/scripts/` (ticket search, ticket → PRD, plan state, transitions, notify, sprints, people, PR open/comment, review depth), all REST over `curl` + `jq`, bash 3.2 compatible.
- Per-project config `.asdlc/jira.conf` (`KEY=value`, parsed against an allowlist, never sourced) from `jira/templates/jira.conf`. Tokens stay in env vars (`JIRA_EMAIL`, `JIRA_TOKEN`, `BITBUCKET_TOKEN`). `/asdlc:jira-setup` pre-fills it from older in-repo env vars, checks tokens, makes test calls to Jira and Bitbucket, verifies workflow statuses, and creates `docs/access-rules.md` and `docs/known-traps.md` from templates.
- Fixture mode (`--fixtures <dir>`) on every Jira/Bitbucket script, and an offline test suite (`tests/jira/run.sh`) run in CI.
- `/asdlc:implement-prd --plan-only` (plan, stamp, stop for approval) and `--execute <plan>` (run only a plan that checks RUNNABLE). The default pipeline mode is unchanged apart from the foreground-subagent rule.

[1.1.0]: https://github.com/mumerfarooq-con/asdlc-tools/releases/tag/asdlc--v1.1.0

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
