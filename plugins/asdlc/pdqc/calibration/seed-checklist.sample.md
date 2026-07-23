# PDQC Seed Checklist (Jira-calibrated) — SAMPLE

*Sample output of `extract_seed_checklist.py`, shown for format only (ticket keys are synthetic). These checks run FIRST in Phase 1 and are tagged `source: seed_checklist`. Each is a recurring defect pattern mined from the Jira history — i.e. something the existing PRD Implementor and PR Reviewer demonstrably let through.*

- Tickets scanned: **12**
- Bug/quality tickets (backend-only): **11**
- Pattern matches: **16** across **10** patterns
- Unmatched tickets (need manual review): **0**

## Contract and Consistency

- [ ] **API contract / naming inconsistency** — seen in 1 ticket(s). `seed_pattern_ref: contract-drift`
      Examples: PROJ-103
- [ ] **Architectural / layering drift** — seen in 1 ticket(s). `seed_pattern_ref: layering`
      Examples: PROJ-106

## Error and Edge Handling

- [ ] **Unhandled edge / boundary case** — seen in 2 ticket(s). `seed_pattern_ref: unhandled-edge`
      Examples: PROJ-102, PROJ-110
- [ ] **Inconsistent or leaky error responses** — seen in 1 ticket(s). `seed_pattern_ref: inconsistent-error-shape`
      Examples: PROJ-101

## Documentation

- [ ] **Missing documentation** — seen in 2 ticket(s). `seed_pattern_ref: doc-missing`
      Examples: PROJ-104, PROJ-112
- [ ] **Missing rationale (the 'why')** — seen in 2 ticket(s). `seed_pattern_ref: doc-why`
      Examples: PROJ-104, PROJ-112
- [ ] **Documentation drift (docs vs behavior)** — seen in 1 ticket(s). `seed_pattern_ref: doc-drift`
      Examples: PROJ-105

## Maintainability and Technical Debt

- [ ] **Duplication / dead code / complexity / debt marker** — seen in 3 ticket(s). `seed_pattern_ref: duplication-deadcode`
      Examples: PROJ-106, PROJ-109, PROJ-110

## Operability

- [ ] **Missing validation / authz / abuse protection** — seen in 2 ticket(s). `seed_pattern_ref: validation-gap`
      Examples: PROJ-108, PROJ-109
- [ ] **Config / secret / migration readiness** — seen in 1 ticket(s). `seed_pattern_ref: config-secret`
      Examples: PROJ-107

---

**Refinement:** keyword bucketing is a floor. For semantic clustering that catches patterns the keywords miss, re-run with `--emit-llm-input corpus.jsonl` and hand the resolution corpus to a model to cluster by root cause, then fold new clusters back into `PATTERNS`.
