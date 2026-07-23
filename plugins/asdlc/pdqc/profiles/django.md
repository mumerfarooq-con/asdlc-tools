# Stack Profile: Python / Django (+ DRF)

**Profiles are the only stack-specific artifacts in PDQC.** Each is external and swappable. It tells inspectors *how* the universal principles manifest in Django/DRF — it is never the source of a principle. Adding a new stack means writing a sibling profile with the same section headings; the inspectors and rubric do not change.

Everything below is a **detection heuristic**, not a rule. The rule always comes from the repo's own standards docs or its dominant observed convention. Where this profile and the repo's docs disagree, the docs win.

## Contract and consistency

- Routing via `urls.py`, DRF `DefaultRouter`, `ViewSet`, and `APIView`. Enumerate endpoints from routers and explicit paths.
- Request/response schemas via DRF serializers; field casing set by serializer field names or a global renderer. Check for one casing convention across all serializers.
- Error envelope via DRF's `exception_handler` (custom or default). A consistent envelope means one handler shapes all errors; multiple ad-hoc error dicts are a deviation.
- Pagination via DRF pagination classes; check for one class applied consistently, not per-view reinvention.
- Layering signal: business logic living in `views.py` vs. a `services/`/`selectors.py` layer. "Fat views" are the common architectural drift.

## Error and edge handling

- Exception surface: `Http404`, DRF `ValidationError`/`APIException`, `PermissionDenied`, and custom exceptions. Bare `except:` and `except Exception:` are broad-catch signals.
- Transaction boundaries: `transaction.atomic` around multi-write operations; its absence around related writes is a partial-failure risk.
- Lookups: `get_object_or_404` vs. manual `.get()` that can raise `DoesNotExist` uncaught.
- Edge signals: missing `required`/`allow_null`/`max_length` on serializer fields; unbounded querysets returned without pagination.

## Documentation

- Docstrings on views, serializers, services; `help_text` on model fields.
- API schema via `drf-spectacular` / `drf-yasg` annotations; undocumented endpoints show as gaps in the generated schema.
- README + settings docs for the run/config story.
- Rationale gaps: custom `save()`/`clean()` overrides, signal handlers, and manual SQL without a "why" comment.

## Maintainability and technical debt

- Complexity: long view methods, deep nesting, fat models mixing persistence and business rules.
- Query health: N+1 patterns absent `select_related`/`prefetch_related`; `.all()` in loops.
- Debt markers: `# TODO`/`# FIXME`, `@pytest.mark.skip`/`@skip`/`@expectedFailure`, deprecated Django/DRF APIs (check against the pinned version).
- Duplication: repeated serializer/validation logic that a mixin or base class should own.

## Operability

- Config: `settings/` split (base/dev/prod), secrets from environment (`os.environ`/`django-environ`), never committed. `DEBUG=False` and a real `ALLOWED_HOSTS` for prod.
- Observability: `LOGGING` configured; not bare `print`.
- Health: a health/readiness endpoint.
- DB: migrations present, reversible, and not destructive against live data (watch `RemoveField`, non-nullable adds without defaults).
- Authz: DRF `permission_classes` on **every** view; `AllowAny` should be deliberate and rare. A view with no permission class inheriting a permissive default is a blocker candidate.
- Throttling: DRF throttle classes where the contract implies rate limits.
- Verify runnability with a throwaway `python manage.py check`, `makemigrations --check`, and a test run — never mutate the repo.
