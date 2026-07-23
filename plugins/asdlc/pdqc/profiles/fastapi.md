# Stack Profile: Python / FastAPI (+ Pydantic, SQLAlchemy)

**Profiles are the only stack-specific artifacts in PDQC.** Each is external and swappable. It tells inspectors *how* the universal principles manifest in FastAPI — it is never the source of a principle. Adding a new stack means writing a sibling profile with the same section headings; the inspectors and rubric do not change.

Everything below is a **detection heuristic**, not a rule. The rule always comes from the repo's own standards docs or its dominant observed convention. Where this profile and the repo's docs disagree, the docs win.

## Contract and consistency

- Routing via `APIRouter` and path-operation decorators. Enumerate endpoints from routers and every `include_router` mount (watch for duplicate prefixes and unmounted routers).
- Request/response schemas via Pydantic models; `response_model` on every route — routes returning raw dicts or ORM objects bypass the contract. Casing set by `alias_generator`/`model_config`; check for one casing convention across all models.
- Error envelope via app-level `exception_handler` registrations. A consistent envelope means handlers shape all errors; scattered `raise HTTPException(detail=...)` with ad-hoc shapes is a deviation.
- Pagination has no framework default — check that one convention (limit/offset params, cursor, or a shared dependency) is applied consistently, not reinvented per route.
- Layering signal: business logic living in path-operation functions vs. a `services/` layer; `Depends` chains used for wiring, not as a place to hide business rules. "Fat handlers" are the common architectural drift.

## Error and edge handling

- Exception surface: `HTTPException`, custom exceptions with registered handlers, Pydantic `ValidationError`. Bare `except:` and `except Exception:` are broad-catch signals.
- Async correctness: blocking calls (sync DB drivers, `requests`, `time.sleep`) inside `async def` routes stall the event loop; sync-in-async is this stack's signature defect.
- Transaction boundaries: session commit/rollback owned in one place (a dependency or unit-of-work), not per-handler; multi-write operations without a transaction are a partial-failure risk.
- Lookups: `.one()`/`.scalar_one()` vs. unchecked `.first()` whose `None` propagates; a shared get-or-404 helper vs. per-route reinvention.
- Edge signals: Pydantic fields missing constraints (`max_length`, `ge`/`le`, optionality made explicit); unbounded queries returned without pagination; background tasks that fail silently.

## Documentation

- FastAPI generates OpenAPI from the code: routes missing `summary`/`description`/`response_model`/`status_code` show up directly as schema gaps — the generated `/docs` is the audit surface.
- Docstrings on services and non-trivial dependencies; `Field(description=...)` on model fields that aren't self-evident.
- README + settings docs for the run/config story.
- Rationale gaps: custom middleware, dependency overrides, event handlers (`lifespan`), and manual SQL without a "why" comment.

## Maintainability and technical debt

- Complexity: long path-operation functions, deep `Depends` chains, business rules inside Pydantic validators.
- Query health: N+1 patterns absent `selectinload`/`joinedload`; queries in loops.
- Debt markers: `# TODO`/`# FIXME`, `@pytest.mark.skip`/`xfail`, Pydantic v1 idioms in a v2 codebase (`.dict()`, `class Config`), deprecated Starlette/FastAPI APIs (check against the pinned version).
- Duplication: near-identical request/response models that a base model should own; the same validation logic in multiple validators.

## Operability

- Config: settings via `pydantic-settings`/`BaseSettings`, secrets from environment, never committed; no debug/reload flags in the prod entrypoint.
- Observability: `logging` configured (or structlog); not bare `print`.
- Health: a health/readiness endpoint.
- DB: Alembic migrations present, reversible, and not destructive against live data (watch column drops and non-nullable adds without server defaults).
- Authz: an auth dependency (`Depends(get_current_user)` or router-level `dependencies=[...]`) on **every** protected route; a route with no auth dependency should be deliberate and rare — an exposed mutation route without one is a blocker candidate.
- Throttling: rate limiting (e.g. `slowapi`) where the contract implies limits.
- Verify runnability with a throwaway import check of the app module, `alembic check` (or `upgrade --sql` dry run), and a test run — never mutate the repo.
