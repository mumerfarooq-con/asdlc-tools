#!/usr/bin/env python3
"""
extract_seed_checklist.py — PDQC calibration step (spec §10).

Turns an exported Jira CSV of reported bugs into a seed checklist that biases
the Pre-Delivery Quality Check toward the defect patterns that actually slipped
through the existing agents.

What it does (mechanical, deterministic):
  1. Loads the CSV, coalescing Jira's duplicated multi-value columns
     (Comments, Components, Labels get renamed Comments.1, .2 ... by pandas).
  2. Selects backend + bug/quality tickets (configurable; ownership labels are lossy,
     so it matches on issue type AND on backend signals in component/label/text).
  3. Builds a per-ticket text blob from summary + description + RESOLUTION + comments
     (the resolution is where the real pattern lives).
  4. Buckets each ticket into one or more PDQC inspectors via keyword patterns,
     weighted toward the two dominant classes (poor-practice-slip, doc-gap).
  5. Aggregates into recurring patterns with counts + example ticket keys.
  6. Emits seed-checklist.md grouped by inspector.

What it does NOT do:
  - Semantic clustering. Keyword bucketing is a floor, not a ceiling. For richer
    clustering, pass --emit-llm-input to also dump the resolution corpus as JSONL
    for a follow-up model pass. See the note at the bottom of the generated file.

Usage:
  python extract_seed_checklist.py bugs.csv -o seed-checklist.md
  python extract_seed_checklist.py bugs.csv --backend-only --emit-llm-input corpus.jsonl
"""

import argparse
import csv
import json
import re
import sys
from collections import defaultdict, Counter
from pathlib import Path

# ---------------------------------------------------------------------------
# Column detection — Jira exports vary wildly in header names.
# ---------------------------------------------------------------------------
COLUMN_ALIASES = {
    "key":        ["issue key"],  # exact only — do NOT merge with "Issue id"
    "type":       ["issue type", "type"],
    "status":     ["status"],
    "resolution": ["resolution"],
    "summary":    ["summary", "title"],
    "description":["description"],
    "components": ["component/s", "components", "component"],
    "labels":     ["labels", "label"],
    "comments":   ["comment", "comments"],
}

# Issue types we treat as defects/quality (case-insensitive substring match).
BUG_TYPES = ["bug", "defect", "fault", "improvement", "tech debt", "task"]

# Backend signals used when --backend-only is set (ownership labels are lossy,
# so we also match code-ish signals in text).
BACKEND_SIGNALS = [
    "backend", "api", "endpoint", "server", "django", "drf", "serializer",
    "model", "migration", "queryset", "viewset", "database", "db ", "sql",
]

# ---------------------------------------------------------------------------
# Pattern -> inspector mapping. Each pattern is (id, inspector, regex, label).
# Weighted toward the two dominant classes; ordered roughly by expected value.
# Tune these against your actual export.
# ---------------------------------------------------------------------------
PATTERNS = [
    # ---- Dominant class in the calibration export: implementation drifted from the PRD / design spec ----
    ("response-field-gap", "contract_consistency",
     r"missing .*(field|param|duration|column)|response is missing|does not return|not return|"
     r"missing from .*(response|listing|api)|field .*(missing|required)",
     "API response missing fields required by design"),
    ("design-mismatch", "contract_consistency",
     r"not implemented|present in design|missing from .*design|as per design|"
     r"do(es)? not match .*(requirement|design|ticket)|requirement is attached|"
     r"not a white ?listed|variables .*not implemented",
     "Implementation does not match PRD / design spec"),
    ("missing-endpoint", "contract_consistency",
     r"api is missing|endpoint .*(missing|not available|is missing)|"
     r"no (patch|put|get|post) .*(request|api)|need an endpoint",
     "Designed endpoint or operation not implemented"),
    ("contract-drift", "contract_consistency",
     r"naming|casing|snake_case|camel ?case|pagination|inconsistent (with|field|response|api)|"
     r"contract|versioning",
     "API naming / shape / consistency drift"),
    ("layering", "contract_consistency",
     r"business logic in (view|controller)|fat view|fat model|coupling|circular|layer(ing)?|architecture",
     "Architectural / layering drift"),

    # ---- Error / edge / state-lifecycle handling ----
    ("state-lifecycle", "error_edge",
     r"soft.?delete|status remains|retain.*status|should reset|reset to|not regenerated|regenerat|"
     r"stale|still attach|should not be able|refresh|remains (published|draft)|unique per user",
     "State / lifecycle correctness (wrong or stale state after a transition)"),
    ("delivery-gap", "error_edge",
     r"email .*(not|isn.?t) (sent|triggered|received|delivered)|no email|not triggered|"
     r"notification .*(not|isn.?t) (sent|received)|websocket|in.?app notification|"
     r"mark(ed)? .*as (sent|delivered)",
     "Notification / email / websocket delivery gap"),
    ("input-edge", "error_edge",
     r"\+ ?sign|special character|multi.?select|search .*not working|does not support|subdomain|"
     r"contains .* sign|off by one|negative|overflow|boundary|edge case",
     "Input / boundary handling edge case"),
    ("unhandled-null-empty", "error_edge",
     r"\bnull\b|\bnone\b|\bempty\b|missing (value|param)|no keyword|not mandatory|concurren|race",
     "Unhandled null / empty / missing-value case"),
    ("inconsistent-error-shape", "error_edge",
     r"error (response|shape|format|envelope)|inconsistent error|status code|\b500\b|"
     r"traceback|stack ?trace|error message",
     "Inconsistent / leaky / unclear error responses"),

    # ---- Operability / storage / access ----
    ("storage-file", "operability",
     r"\bs3\b|presigned|upload|attachment|image upload|photo .*(field|upload)|"
     r"filename .*(not )?preserved|raw .*path",
     "File / storage handling (S3, uploads, presigned URLs)"),
    ("access-control", "operability",
     r"access control|unenrolled|permission|authorization|authz|unprotected|cannot cancel|"
     r"should not (see|access)",
     "Access control / authorization gap"),
    ("validation-gap", "operability",
     r"validation|not validated|invalid input|sanitiz|injection|rate limit",
     "Missing input validation / abuse protection"),
    ("config-secret", "operability",
     r"\bsecret\b|hardcoded|env(ironment)? var|debug=true|allowed_hosts|"
     r"migration (fail|broke|unsafe)|sender|admin@",
     "Config / secret / sender / migration readiness"),

    # ---- Documentation ----
    ("doc-missing", "documentation",
     r"undocumented|no docstring|missing doc|not documented|unclear|confus|hard to understand|no comment",
     "Missing documentation"),
    ("doc-drift", "documentation",
     r"doc(s|umentation)? (wrong|outdated|stale|mismatch|out of date)|outdated copy|does not match|contradict",
     "Documentation drift (docs vs behavior)"),
    ("doc-why", "documentation",
     r"\bwhy\b|rationale|reason|intent|no explanation|workaround",
     "Missing rationale (the 'why')"),

    # ---- Maintainability / debt ----
    ("duplication-deadcode", "maintainability_debt",
     r"duplicat|copy ?paste|dead code|unused|refactor|complex|too long|magic (number|string)|"
     r"\btodo\b|\bfixme\b|\bhack\b",
     "Duplication / dead code / complexity / debt marker"),
]

INSPECTOR_ORDER = [
    "contract_consistency", "error_edge", "documentation",
    "maintainability_debt", "operability",
]
INSPECTOR_TITLES = {
    "contract_consistency": "Contract and Consistency",
    "error_edge": "Error and Edge Handling",
    "documentation": "Documentation",
    "maintainability_debt": "Maintainability and Technical Debt",
    "operability": "Operability",
}


def load_rows(path):
    """Read CSV, coalescing duplicated multi-value columns (Comments.1 etc.)."""
    with open(path, newline="", encoding="utf-8-sig", errors="replace") as f:
        reader = csv.reader(f)
        headers = next(reader, [])
        raw_rows = [row for row in reader]
    # Map each logical field to all column indices whose header alias-matches it.
    lower = [h.strip().lower() for h in headers]
    field_cols = {}
    for field, aliases in COLUMN_ALIASES.items():
        cols = [i for i, h in enumerate(lower)
                if any(h == a or h.startswith(a) for a in aliases)]
        field_cols[field] = cols
    rows = []
    for r in raw_rows:
        rec = {}
        for field, cols in field_cols.items():
            vals = [r[i].strip() for i in cols if i < len(r) and r[i].strip()]
            rec[field] = " \n ".join(vals)
        if any(rec.values()):
            rows.append(rec)
    return rows, headers


def is_bug(rec):
    t = rec.get("type", "").lower()
    return any(bt in t for bt in BUG_TYPES) if t else True  # if no type col, keep all


def is_backend(rec):
    blob = " ".join(rec.get(k, "") for k in ("components", "labels", "summary", "description")).lower()
    return any(sig in blob for sig in BACKEND_SIGNALS)


def blob_of(rec):
    return " \n ".join(rec.get(k, "") for k in
                       ("summary", "description", "resolution", "comments")).lower()


def classify(rec):
    """Return list of (pattern_id, inspector, label) this ticket matches."""
    text = blob_of(rec)
    hits = []
    for pid, inspector, rx, label in PATTERNS:
        if re.search(rx, text, flags=re.IGNORECASE):
            hits.append((pid, inspector, label))
    return hits


def main():
    ap = argparse.ArgumentParser(description="Jira CSV -> PDQC seed checklist")
    ap.add_argument("csv_path")
    ap.add_argument("-o", "--out", default="seed-checklist.md")
    ap.add_argument("--backend-only", action="store_true",
                    help="Keep only tickets with backend signals (labels are lossy, so text is also matched).")
    ap.add_argument("--emit-llm-input", metavar="JSONL",
                    help="Also dump the resolution corpus as JSONL for a semantic clustering pass.")
    args = ap.parse_args()

    if not Path(args.csv_path).exists():
        sys.exit(f"CSV not found: {args.csv_path}")

    rows, headers = load_rows(args.csv_path)
    total = len(rows)
    bugs = [r for r in rows if is_bug(r)]
    if args.backend_only:
        before = len(bugs)
        bugs = [r for r in bugs if is_backend(r)]
        dropped = before - len(bugs)
        if before and dropped / before > 0.25:
            print(f"WARNING: --backend-only dropped {dropped}/{before} tickets "
                  f"({dropped/before:.0%}). If the Team/Component fields are empty and this "
                  f"export is already scoped, re-run WITHOUT --backend-only.", file=sys.stderr)

    # pattern_id -> {inspector, label, tickets:[key], count}
    patterns = defaultdict(lambda: {"inspector": None, "label": None, "tickets": []})
    unmatched = []
    for rec in bugs:
        key = rec.get("key") or "(no-key)"
        hits = classify(rec)
        if not hits:
            unmatched.append(key)
            continue
        for pid, inspector, label in hits:
            patterns[pid]["inspector"] = inspector
            patterns[pid]["label"] = label
            patterns[pid]["tickets"].append(key)

    # Group patterns by inspector, sorted by frequency.
    by_inspector = defaultdict(list)
    for pid, data in patterns.items():
        by_inspector[data["inspector"]].append((pid, data))
    for insp in by_inspector:
        by_inspector[insp].sort(key=lambda x: len(x[1]["tickets"]), reverse=True)

    matched = sum(len(d["tickets"]) for d in patterns.values())

    # ---- write markdown ----
    out = []
    out.append("# PDQC Seed Checklist (Jira-calibrated)")
    out.append("")
    out.append("*Generated by `extract_seed_checklist.py`. These checks run FIRST in "
               "Phase 1 and are tagged `source: seed_checklist`. Each is a recurring "
               "defect pattern mined from the Jira history — i.e. something the existing "
               "PRD Implementor and PR Reviewer demonstrably let through.*")
    out.append("")
    out.append(f"- Tickets scanned: **{total}**")
    out.append(f"- Bug/quality tickets{' (backend-only)' if args.backend_only else ''}: **{len(bugs)}**")
    out.append(f"- Pattern matches: **{matched}** across **{len(patterns)}** patterns")
    out.append(f"- Unmatched tickets (need manual review): **{len(unmatched)}**")
    out.append("")

    for insp in INSPECTOR_ORDER:
        items = by_inspector.get(insp, [])
        if not items:
            continue
        out.append(f"## {INSPECTOR_TITLES[insp]}")
        out.append("")
        for pid, data in items:
            tickets = data["tickets"]
            examples = ", ".join(tickets[:8]) + (" …" if len(tickets) > 8 else "")
            out.append(f"- [ ] **{data['label']}** — seen in {len(tickets)} ticket(s). "
                       f"`seed_pattern_ref: {pid}`")
            out.append(f"      Examples: {examples}")
        out.append("")

    if unmatched:
        out.append("## Unmatched (manual triage)")
        out.append("")
        out.append("These bug tickets matched no keyword pattern. Review them by hand — "
                   "they are the most likely source of a *new* pattern the keyword rules miss.")
        out.append("")
        out.append("  " + ", ".join(unmatched[:40]) + (" …" if len(unmatched) > 40 else ""))
        out.append("")

    out.append("---")
    out.append("")
    out.append("**Refinement:** keyword bucketing is a floor. For semantic clustering that "
               "catches patterns the keywords miss, re-run with `--emit-llm-input corpus.jsonl` "
               "and hand the resolution corpus to a model to cluster by root cause, then fold "
               "new clusters back into `PATTERNS`.")
    out.append("")

    Path(args.out).write_text("\n".join(out), encoding="utf-8")
    print(f"Wrote {args.out}: {len(bugs)} bug tickets, {len(patterns)} patterns, "
          f"{len(unmatched)} unmatched.")

    if args.emit_llm_input:
        with open(args.emit_llm_input, "w", encoding="utf-8") as f:
            for rec in bugs:
                f.write(json.dumps({
                    "key": rec.get("key"),
                    "summary": rec.get("summary"),
                    "resolution": rec.get("resolution"),
                    "comments": rec.get("comments"),
                }, ensure_ascii=False) + "\n")
        print(f"Wrote {args.emit_llm_input} for semantic clustering.")


if __name__ == "__main__":
    main()
