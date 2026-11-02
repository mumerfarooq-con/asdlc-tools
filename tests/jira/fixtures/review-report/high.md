# PR review PROJ-1

PR REVIEW: APPROVE

## Must-fix
None.

## Human must read
Risk tier: high
| # | Hunk | Reason | Why a human must read it |
|---|---|---|---|
| 1 | app/migrations/0002_add_col.py:1-30 | migration | SECRET-WHY-ONE drops a column |
| 2 | `app/api/views.py:40-58` | `api-contract` | renames a response field |
| 3 | app/settings.py:12-12 | other | SECRET-WHY-THREE |
| 4 | app/api/views.py:100-110 | api-contract | repeated reason |

Suggest a teammate approves this PR on Bitbucket.

## Panel summary
- ok
