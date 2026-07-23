# PDQC Triage Rubric

Applied by the **QA Chair** in Phase 2 to every finding emitted by the inspectors. The Chair assigns `severity` (confirming or adjusting the inspector's proposal) and `classification`. Inspectors propose; the Chair decides.

## Step 1 — Evidence gate (drop-first)

Before anything else, discard any finding that lacks **both** a concrete `location` (`file:line`) **and** a concrete `impact`. "This could be cleaner" with no stated cost is not a finding. This gate is the single most important lever against noise.

## Step 2 — Severity

- **blocker** — violates a documented standard in the repo's own standards docs; **or** breaks the public API contract (shape, status codes, auth, envelope); **or** is a production-readiness gap that would degrade real users (missing authz on an endpoint, secret in source, unsafe migration, unhandled failure that reaches the client inconsistently).
- **major** — a real maintainability, consistency, or documentation gap that will cost future developers, but does not break the contract or endanger production. Most convention-drift and missing-rationale findings land here.
- **minor** — local nit or cosmetic inconsistency with negligible downstream cost.

## Step 3 — Classification (the delivery gate)

- `must_fix_before_delivery` = **every blocker**, plus any **major that touches the public contract or one of the two calibrated defect classes** (poor-practice-slip or documentation-gap — see the seed checklist). Rationale: these are exactly the classes the existing agents demonstrably miss, so they get promoted.
- `log_as_debt` = everything else. Ships **only** with an explicit accept decision recorded on the production-readiness checklist at sign-off. Debt is a valid outcome; silent debt is not.

## Step 4 — Dedupe and merge

- Findings sharing a location **and** root cause merge into one, keeping the **highest** severity and the **union** of recommendations.
- **Cross-inspector overlap** (e.g. an inconsistent error envelope flagged by both `contract_consistency` and `error_edge`) merges into a single finding whose `inspector` array carries both tags. Do not report it twice.

## Step 5 — Confidence handling

- `low`-confidence findings are reported but **never auto-gated as blockers**. They surface in a dedicated "for human judgment" section of the report regardless of severity.
- `high`/`medium` findings follow the gate in Step 3 normally.

## Chair dispute resolution

When two inspectors disagree on severity for a merged finding, the Chair takes the **higher** severity and records the dissent in one line. The Chair arbitrates severity; it does not silently overrule an inspector's evidence.
