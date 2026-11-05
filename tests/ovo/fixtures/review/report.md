PR REVIEW: REQUEST_CHANGES

The change adds a refund endpoint and a settings switch. The refund path has no permission check and
accepts any amount, so one finding blocks.

## Must-fix (BLOCKER)
1. **BLOCKER** app/refunds.py:12 — no permission check on refund — any signed-in user can refund any order — require the order's owner or staff (security, correctness)

## Should-fix (MAJOR)
2. **MAJOR** app/refunds.py:15 — the amount is not capped at the order total — a refund can exceed the payment — reject amounts above the total (correctness)

## Nits (MINOR)
3. **MINOR** app/settings.py:7 — a hard-coded host list — it drifts from the deploy config — read it from the environment (architecture)

## Adjudications
- Architecture's MAJOR on naming downgraded to MINOR: taste, not a defect.

## Panel summary
- security: BLOCK; correctness: CONCERNS; architecture: CONCERNS.

## Human must read
Risk tier: high
| # | Hunk | Reason | Why a human must read it |
|---|---|---|---|
| 1 | `app/refunds.py:10-20` | billing | refunds move money and no test covers the cap |
| 2 | app/refunds.py:12 | authz | the permission check decides who can refund |
| 3 | app/settings.py:5-9 | env-config | the host list must match each environment |
Suggest a teammate's approval on Bitbucket before merging.
