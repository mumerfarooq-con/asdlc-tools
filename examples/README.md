# Example reports

Real, unedited output from the two review workflows, run against well-known open-source projects on 2026-07-23. Only local filesystem paths were redacted.

| Report | Workflow | Target |
|---|---|---|
| [`pdqc-healthchecks.md`](pdqc-healthchecks.md) | `/asdlc:pdqc` — 5 parallel inspectors + QA Chair, triage rubric applied | [healthchecks/healthchecks](https://github.com/healthchecks/healthchecks) @ `2f79af0` |
| [`pr-review-council-wagtail-14411.md`](pr-review-council-wagtail-14411.md) | `/asdlc:review-pr --council` — 3 lens panelists + Review Chair, GitHub mode | [wagtail/wagtail#14411](https://github.com/wagtail/wagtail/pull/14411) (JPEG-XL support) |

## What these demonstrate

- **PDQC on healthchecks**: 38 raw findings triaged to 26, later corrected to 25 standing (1 verified blocker, 11 must-fix work items, 14 logged as debt). Note the Chair's adjudications section — four proposed "blockers" were downgraded because healthchecks *documents* its developer-friendly defaults; the rubric's evidence gate and severity calibration are doing real work, not rubber-stamping inspector output.
- **A public retraction, on purpose**: the report originally carried a second blocker (EE-8, a claimed dead code path from a Django `F()` expression). Two agents "verified" it by reading the cited lines; a human follow-up with an executable reproduction showed Django 6 behavior makes the code correct, and the finding was retracted in place rather than silently removed. That's the failure mode these workflows are designed around — treat findings as leads, reproduce before you file.
- **Council on wagtail#14411**: verdict APPROVE with should-fixes — three panelists reviewed through disjoint lenses (security caught a JXL decompression-bomb gap in the upload gate; correctness caught missing `skipUnless` guards that would break CI without libjxl; architecture caught a broken `elif` dispatch pattern and missing release notes), and the Chair reconciled an explicit severity dispute between two panelists on the same line of code.

## Framing

Both target projects are high-quality, actively maintained codebases — that is *why* they were chosen. PDQC's purpose is to surface the residual, cross-cutting risk that per-PR review structurally cannot see; finding some in excellent codebases is the expected outcome, not a criticism of their maintainers. Findings are heuristic agent output: treat them as leads to verify, not verdicts. If you maintain either project and want a report corrected or removed, open an issue.

## Reproduce

```
/plugin install asdlc@asdlc-tools
/asdlc:pdqc                      # from a checkout of the target repo
/asdlc:review-pr <pr-url> --council
```

These runs used Claude Sonnet for inspectors/panelists and Claude Opus for the two chairs.
