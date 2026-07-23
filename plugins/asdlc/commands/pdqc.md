---
name: pdqc
description: Run the Pre-Delivery Quality Check on a near-ready-to-ship codebase. Codebase-scoped, not diff-scoped. Produces findings and delegates fixes; never edits code.
---

# /pdqc — Pre-Delivery Quality Check

Run this once on a codebase approaching delivery. It catches the class of issues per-PR review cannot see because they only exist in the assembled whole: cross-cutting inconsistency, documentation gaps, maintainability and debt, error/edge coverage, and production readiness.

**Hard constraint (inherited from the PR Reviewer):** PDQC never modifies code. It produces findings and delegates required changes to the PRD Implementor.

## Phase 0 — Discovery and context assembly

1. Run the discovery contract (`${CLAUDE_PLUGIN_ROOT}/pdqc/discovery/discovery.md`). Locate the repo's standards docs, architecture docs, and any existing sub-agent/command definitions. If discovery is not yet trusted, load the explicit fallback config (`${CLAUDE_PLUGIN_ROOT}/pdqc/discovery/pdqc.config.example.yaml`) — do not debug discovery and detection at the same time.
2. Select the stack profile (v0: `${CLAUDE_PLUGIN_ROOT}/pdqc/profiles/django.md`). If none matches, proceed with convention-derivation only and note the gap.
3. Build the **codebase map**: every route with method/params/response shape; the module/layer graph; the set of error types and where raised; data models; the config surface; external dependencies. This is the shared context all inspectors read.
4. **Calibration (optional).** If `use_seed_checklist: true` and a seed checklist exists, load it from the `seed_checklist` path in the target repo's `pdqc.config.yaml` (the plugin does not ship one — generate it with `${CLAUDE_PLUGIN_ROOT}/pdqc/calibration/extract_seed_checklist.py`; format sample: `${CLAUDE_PLUGIN_ROOT}/pdqc/calibration/seed-checklist.sample.md`); its checks run first and are tagged `source: seed_checklist`. If it is absent or disabled — the default for any codebase without usable ticket history — run in **blind mode**: the inspectors apply their charters uniformly with no project-specific prioritization. Blind mode is fully supported and is the expected path for a fresh codebase; the seed only sharpens *where* inspectors look first, never *what* they are able to find.

Emit the **resolved input manifest**: which standards docs were found, which conventions were derived, what fell back to the stack profile. Attach it to the final report.

## Phase 1 — Parallel inspection

Dispatch the five inspectors concurrently. Each reads the codebase map, the repo standards docs, the stack profile, and the seed checklist, and emits findings conforming to `${CLAUDE_PLUGIN_ROOT}/pdqc/schema/finding.schema.json`:

- `inspector-contract-consistency`
- `inspector-error-edge`
- `inspector-documentation`
- `inspector-maintainability-debt`
- `inspector-operability`

## Phase 2 — Triage and synthesis

Hand all findings to `qa-chair`, which applies `${CLAUDE_PLUGIN_ROOT}/pdqc/rubric/triage-rubric.md`: evidence-gate, severity, classification, dedupe/merge (including cross-inspector overlap), and confidence handling. Output: the consolidated QA report.

## Phase 3 — Remediation delegation

Package every `must_fix_before_delivery` finding as a work item for the **PRD Implementor**. Documentation fixes route the same way. PDQC does not edit code.

## Phase 4 — Verification and sign-off

After the Implementor lands fixes, re-run the owning inspector on the changed surfaces to confirm resolution and check for regression. Produce the deliverables: QA report, technical-debt register, remediation work items, and the production-readiness checklist with explicit accept/waive decisions on anything shipped as debt.
