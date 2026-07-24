# asdlc-tools

[![validate](https://github.com/mumerfarooq-con/asdlc-tools/actions/workflows/validate.yml/badge.svg)](https://github.com/mumerfarooq-con/asdlc-tools/actions/workflows/validate.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![version](https://img.shields.io/github/v/tag/mumerfarooq-con/asdlc-tools?label=version&filter=asdlc--v*)](CHANGELOG.md)

Framework-agnostic agentic SDLC tooling, distributed as a Claude Code plugin. This repo is both the plugin source and its marketplace. The workflows carry universal engineering principles; everything stack-specific lives in swappable [PDQC profiles](plugins/asdlc/pdqc/profiles/) and the target repo's own standards docs (`CLAUDE.md`, README), which always win.

Three workflows cover the software delivery cycle end to end: a **PRD Implementor** that plans, builds, reviews, and tests from a spec; a **PR Review council** (or a cheap solo reviewer) for diffs; and **PDQC**, a pre-delivery quality gate that catches the cross-cutting issues per-PR review structurally cannot see.

**See it work:** [real reports](examples/) from running PDQC against [healthchecks](https://github.com/healthchecks/healthchecks) (26 triaged findings, 2 verified blockers) and the review council against [wagtail#14411](https://github.com/wagtail/wagtail/pull/14411) (3 lenses, reconciled verdict).

## Commands

The `asdlc` plugin ships three workflow entrypoints (invocation names come from the command filenames):

- `/asdlc:implement-prd` — PRD Implementor: plans, executes, reviews, and tests work from a PRD.
- `/asdlc:review-pr` — PR Review: a single reviewer by default, or a 3-panelist council with `--council`.
- `/asdlc:pdqc` — Pre-Delivery Quality Check: a codebase-scoped quality gate that produces findings and delegates fixes (never edits code). Stack profiles shipped: Django, FastAPI, Node/Express, React — profiles are swappable detection heuristics, and new-stack PRs only need to mirror the section headings of an existing profile.

All fifteen subagents ship inside the one plugin, so cross-workflow references resolve without any extra install.

## Install

```
/plugin marketplace add mumerfarooq-con/asdlc-tools
/plugin install asdlc@asdlc-tools
/reload-plugins
```

## Update

```
/plugin marketplace update asdlc-tools
/reload-plugins
```

## PDQC calibration (optional)

PDQC runs in **blind mode** by default — no project-management data needed. To bias it toward your project's historical defect patterns, generate a seed checklist in your own repo from a Jira CSV export:

```bash
curl -fsSL https://raw.githubusercontent.com/mumerfarooq-con/asdlc-tools/main/plugins/asdlc/pdqc/calibration/extract_seed_checklist.py -o extract_seed_checklist.py
python extract_seed_checklist.py bugs.csv -o pdqc/seed-checklist.md
```

Then set `use_seed_checklist: true` and the `seed_checklist` path in your repo's `pdqc.config.yaml`. The seed checklist is per-project data and is never shipped with the plugin (see `pdqc/calibration/seed-checklist.sample.md` for the format).
