# ASDLC: agentic SDLC workflows for Claude Code

[![validate](https://github.com/mumerfarooq-con/asdlc-tools/actions/workflows/validate.yml/badge.svg)](https://github.com/mumerfarooq-con/asdlc-tools/actions/workflows/validate.yml)
[![version](https://img.shields.io/github/v/tag/mumerfarooq-con/asdlc-tools?label=version&filter=asdlc--v*)](CHANGELOG.md)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

ASDLC is a Claude Code plugin that runs the delivery loop with specialised subagents and a human approval gate. It takes a spec or a Jira ticket, writes a reviewed plan, builds the plan once you approve it, reviews the pull request, and checks the whole codebase before release.

- **Plans you can trust before any code is written.** Every plan lists what else the change touches, what must keep working, and what a fresh-context critic found. Only a human can approve one, and the approval is bound to a hash of what you read.
- **Review from several angles.** Security, correctness and architecture panelists each review the PR, and a chair reconciles their findings into one verdict.
- **Stack-agnostic.** Your repo's own `CLAUDE.md` and standards docs always win. Stack-specific heuristics live in swappable profiles (Django, FastAPI, Node/Express, React).

This repository is both the plugin source and its marketplace.

## Contents

- [Commands](#commands)
- [Requirements](#requirements)
- [Install](#install)
- [Quick start](#quick-start)
- [How approval works](#how-approval-works)
- [Subagents](#subagents)
- [Examples](#examples)
- [Troubleshooting](#troubleshooting)
- [Contributing and releases](#contributing-and-releases)

## Commands

| Command | What it does |
|---|---|
| `/asdlc:implement-prd <prd>` | **PRD Implementor.** Plans, builds, reviews and tests a spec, one task at a time. `--plan-only` writes a plan and stops for your approval; given a plan file, `--execute` runs it once approved; `--review-only` reviews work that is already done. |
| `/asdlc:plan approve\|replan\|validate <ID>` | Approves, re-plans or validates a plan file. Human-only: the model never runs it on its own. |
| `/asdlc:jira-run` | **Jira leg.** Runs every plan you have approved (implement, open a Bitbucket PR, review, fix), then plans your new tickets and stops for approval. Flags: `--key`, `--sprint`, `--status`, `--plan-only`, `--execute-only`, `--reset-executing`. |
| `/asdlc:jira-setup` | One-time setup for `/asdlc:jira-run` in a repo: writes the project config, checks your tokens with test calls, and adds the docs templates. |
| `/asdlc:review-pr <pr>` | **PR Review.** A single reviewer by default, or a three-panelist council plus chair with `--council`. Works with GitHub, Bitbucket, or a local branch. |
| `/asdlc:pdqc` | **Pre-Delivery Quality Check.** Five inspectors and a QA chair review the whole codebase for the cross-cutting issues that per-PR review can't see. It produces findings and remediation work items, and never edits code. |

## Requirements

- **Claude Code**: the terminal, an IDE extension, or the Code tab of the Claude desktop app.
- **All workflows:** `bash` and `git`. [ripgrep](https://github.com/BurntSushi/ripgrep) is optional; the impact scan falls back to `grep` with identical output.
- **`/asdlc:review-pr`:** the [`gh`](https://cli.github.com/) CLI, signed in, for GitHub PRs. For Bitbucket PRs, a connected Atlassian/Bitbucket MCP server. Without either, it reviews a local branch diff.
- **Jira leg:** Jira Cloud and Bitbucket Cloud, `curl` and `jq`, and API tokens in your shell environment (`JIRA_EMAIL`, `JIRA_TOKEN`, `BITBUCKET_TOKEN`). Tokens never go in a file. See the [Jira leg guide](plugins/asdlc/jira/README.md).
- **PDQC calibration (optional):** Python 3.

## Install

### Claude Code (terminal, IDE, or the desktop app's Code tab)

Run these in a Claude Code session:

```
/plugin marketplace add mumerfarooq-con/asdlc-tools
/plugin install asdlc@asdlc-tools
/reload-plugins
```

The terminal, the IDE extensions and the desktop app's **Code** tab share one plugin install on each machine, so installing in any of them makes ASDLC available in all three. In the desktop app, open the Code tab and run the commands above, or click **+** next to the prompt and choose **Plugins**.

If adding the marketplace fails with an authentication or SSH error, use the HTTPS URL:

```
/plugin marketplace add https://github.com/mumerfarooq-con/asdlc-tools.git
```

### Claude desktop app: Customize → Plugins

ASDLC is not listed in Anthropic's plugin directory, so it does not appear under **Discover** until you add this repository as a marketplace:

1. Open **Customize** in the left sidebar and go to **Plugins**.
2. Click **Add**, then **Add marketplace**, then **Add from a repository**.
3. Enter `mumerfarooq-con/asdlc-tools`.
4. Find **ASDLC** in the list and click **Add**.

A plugin added this way is saved to your claude.ai account and also reaches Claude Code as a synced plugin. Install ASDLC one way on each machine, either here or with `/plugin`, so you don't end up with two copies.

> [!NOTE]
> ASDLC is built for Claude Code. Its workflows run shell scripts and `git` in your repository, so use them from the terminal, an IDE, or the desktop app's Code tab. In regular chat, commands load only as skills and the subagents are ignored. If your organization restricts which marketplaces members can add, the app refuses the repository: ask an Owner to allow `mumerfarooq-con/asdlc-tools`.

### Update

```
/plugin marketplace update asdlc-tools
/reload-plugins
```

## Quick start

### Build from a spec

```
/asdlc:implement-prd prds/checkout-v2.md --plan-only
```

1. The plan lands in `plans/<ID>.plan.md`, with an impact scan, a "Must still work" list and the critic's notes.
2. Read it and answer each open question in the file.
3. Approve it: `/asdlc:plan approve <ID>`.
4. Build it: `/asdlc:implement-prd plans/<ID>.plan.md --execute`.

Every task goes through executor, reviewer and tester before the next one starts. Without `--plan-only`, the command plans and builds in one go, with no approval stop.

### Drive it from Jira

```
/asdlc:jira-setup        # once per repo
/asdlc:jira-run          # plans your new tickets, then stops
/asdlc:plan approve PROJ-142
/asdlc:jira-run          # builds approved plans and opens PRs; plans anything new
```

Each approved ticket gets its own `feature/<KEY>-<slug>` branch, a Bitbucket PR and a review. You merge it yourself. Before each plan runs, the ticket is checked: if it changed after you approved the plan, the plan is marked stale and re-planned in the same run, and you approve it again. Runs are locked and resume after a crash. The [Jira leg guide](plugins/asdlc/jira/README.md) covers configuration, crash recovery and the merge-to-Testing automation.

### Review a pull request

```
/asdlc:review-pr 128                  # single reviewer
/asdlc:review-pr 128 --council        # security, correctness and architecture panel, plus a chair
/asdlc:review-pr feature/x main       # local branch against a base
```

Reports are written to `plans/pr-review-<id>*.md`. Nothing is posted to the PR unless you ask.

### Check a codebase before release

```
/asdlc:pdqc
```

PDQC builds a codebase map and runs five inspectors in parallel: contract consistency, error handling and edge cases, documentation, maintainability and debt, and operability. A QA chair then triages their findings with an evidence-gated rubric. The output is a QA report, a technical-debt register and remediation work items for the PRD Implementor.

**Optional calibration:** to bias PDQC toward your project's past defects, generate a seed checklist from a Jira CSV export:

```bash
curl -fsSL https://raw.githubusercontent.com/mumerfarooq-con/asdlc-tools/main/plugins/asdlc/pdqc/calibration/extract_seed_checklist.py -o extract_seed_checklist.py
python3 extract_seed_checklist.py bugs.csv -o pdqc/seed-checklist.md
```

Then set `use_seed_checklist: true` and the `seed_checklist` path in your repo's `pdqc.config.yaml`. The checklist is your project's data and never ships with the plugin; the format is in [`seed-checklist.sample.md`](plugins/asdlc/pdqc/calibration/seed-checklist.sample.md).

## How approval works

- **Plans are approved in the file, by a person.** `/asdlc:plan approve` checks that the plan is complete: required sections filled, open questions answered, critic blockers answered. It then records a hash of the approved part. No command pre-approves that step, so Claude Code always asks you to confirm it.
- **An edited plan no longer runs.** If the approved part changes after approval, the plan reports `EDITED` and stops until it is re-approved. If a Jira ticket changes after approval, the plan reports `STALE` and is re-planned, and `approve` refuses a stale plan. Agents log progress below a marker that the hash doesn't cover, so a run's own logging never voids the approval.
- **No silent writes to shared systems.** Commits, pushes and Bitbucket writes are not pre-approved; each one is shown to you first.
- **Tokens stay in your environment.** The Jira token is sent only to your configured Jira URL.

## Subagents

All 16 subagents ship inside the one plugin.

| Workflow | Subagents |
|---|---|
| PRD Implementor | `prd-planner`, `plan-critic`, `prd-executor`, `prd-reviewer`, `prd-tester` |
| PR Review | `pr-reviewer`, `pr-reviewer-security`, `pr-reviewer-correctness`, `pr-reviewer-architecture`, `pr-review-chair` |
| PDQC | `inspector-contract-consistency`, `inspector-error-edge`, `inspector-documentation`, `inspector-maintainability-debt`, `inspector-operability`, `qa-chair` |

## Examples

[Unedited reports](examples/) from running the workflows on well-known open-source projects:

- **PDQC on [healthchecks](https://github.com/healthchecks/healthchecks):** 25 standing findings and 1 verified blocker. It also shows a false positive retracted in the open rather than removed.
- **Review council on [wagtail#14411](https://github.com/wagtail/wagtail/pull/14411):** three lenses and a reconciled verdict.

## Troubleshooting

| Symptom | Fix |
|---|---|
| ASDLC isn't under **Discover** in the desktop app | Add the repository as a marketplace first; see [Customize → Plugins](#claude-desktop-app-customize--plugins). |
| The app refuses the repository | Your organization restricts marketplaces. Ask an Owner to allow `mumerfarooq-con/asdlc-tools`. |
| `Permission denied (publickey)` or another clone error | Add the marketplace with the HTTPS URL, or set `CLAUDE_CODE_PLUGIN_PREFER_HTTPS=1`. |
| `git` not found | Install Git, open a new terminal, and check `git --version`. |
| Commands are missing after an update | Run `/plugin marketplace update asdlc-tools`, then `/reload-plugins`. |
| `/asdlc:jira-run` says there is no config | Run `/asdlc:jira-setup` from the repo root. |

## Contributing and releases

See [CONTRIBUTING.md](CONTRIBUTING.md) for the local test loop, validation and the release process. Changes are listed in [CHANGELOG.md](CHANGELOG.md), and releases follow [semantic versioning](https://semver.org/).

Licensed under the [MIT License](LICENSE).
