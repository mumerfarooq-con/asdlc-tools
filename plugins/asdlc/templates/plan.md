<!-- Plan template. Everything in this file is the approved part: what a human signs off on,
     including Critic notes and Open-question answers. `plan-state.sh stamp` adds the header
     block at the top and the progress line at the end; never write either here. Replace every
     <...> hint with real content; `plan-state.sh validate` counts a hint as empty. -->
# Plan: <ID> <title>

## Goal
<Restate the goal in 1-3 sentences, in your own words.>

## Context used
<Ticket sections, comments, access rules and known traps you read, one bullet each. Cite the ones that apply.>

## Visual reference
<One line per image: what it shows. If an image and the text conflict, the text wins and the conflict is an open question. Write "None" if there are no images.>

## Suggested approach verdict
<Agree, partly or disagree with the ticket's suggested approach, and why, checked against the code. Write "None suggested" if there is none.>

## What else uses this
| Usage (file:line) | What it does | Verdict (fine / needs change / unsure) | Why |
|---|---|---|---|
| <path:line> | <what it does with the value> | <fine / needs change / unsure> | <why it is fine or what must change> |

## Must still work
<One checkable example per affected user type, plus one per needs-change or unsure row.>
- <As a <user type>, when <situation>, <expected result>.>

## Changes
<Executor-ready tasks, in order. One "### Task <n>: <title>" block per task.>

### Task <n>: <title>
- <Goal: <what this task achieves>>
- <Files: <files to change>>
- <Acceptance: <how to tell it is done>>
- <Tests: <tests to add or run>>
- <Risk: <what could break>>

## Tests
<Tests to add or run for the whole plan; they must cover every "Must still work" item.>

## Risk
<What could go wrong. If a value grants or denies access, say so here and keep display separate from access.>

## Open questions
<One "- [ ] <question>" per unknown, never a guess. Answer in the file: "- [x] <question> -> Answer: <answer>". Write "None" if there are none.>

## Critic notes
| # | Severity (blocker / should-fix / note) | Finding | Evidence | Planner response |
|---|---|---|---|---|
| <n> | <severity> | <finding> | <file:line or ticket section> | <addressed in <section> / disagree: <reason>> |
