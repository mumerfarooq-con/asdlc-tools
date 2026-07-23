# asdlc-tools

Agentic SDLC tooling, distributed as a Claude Code plugin. This repo is both the plugin source and its marketplace.

## Commands

The `asdlc` plugin ships three workflow entrypoints (invocation names come from the command filenames):

- `/asdlc:implement-prd` — PRD Implementor: plans, executes, reviews, and tests work from a PRD.
- `/asdlc:review-pr` — PR Review: a single reviewer by default, or a 3-panelist council with `--council`.
- `/asdlc:pdqc` — Pre-Delivery Quality Check: a codebase-scoped quality gate that produces findings and delegates fixes (never edits code).

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
