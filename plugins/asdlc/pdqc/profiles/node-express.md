# Stack Profile: Node.js / Express (+ TypeScript)

**Profiles are the only stack-specific artifacts in PDQC.** Each is external and swappable. It tells inspectors *how* the universal principles manifest in Express — it is never the source of a principle. Adding a new stack means writing a sibling profile with the same section headings; the inspectors and rubric do not change.

Everything below is a **detection heuristic**, not a rule. The rule always comes from the repo's own standards docs or its dominant observed convention. Where this profile and the repo's docs disagree, the docs win.

## Contract and consistency

- Routing via `express.Router()` modules and `app.use` mounts. Enumerate endpoints from route files plus their mount prefixes (a route is only real once mounted; watch for double mounts and dead routers).
- Request validation via one middleware convention (zod, joi, express-validator, celebrate) applied at the route edge — handlers reading `req.body` with no validation layer are a deviation. Check one response casing convention across controllers.
- Error envelope via a single centralized 4-arg error middleware; scattered ad-hoc `res.status(500).json({...})` shapes are the drift signal.
- Pagination has no framework default — check that one convention (shared middleware or helper) is applied consistently.
- Layering signal: business logic living in route handlers vs. a `controllers/` + `services/` split; direct DB/ORM calls inside route files are the common architectural drift.

## Error and edge handling

- Async handlers: an `async` handler without try/catch, a wrapper (`asyncHandler`), or Express 5 native handling turns every rejection into a hung request or process crash — this stack's signature defect. Check `unhandledRejection`/`uncaughtException` policy.
- Error middleware registered **after** all routes; `next(err)` used consistently rather than throwing into the void.
- Input coercion: everything in `req.query`/`req.params` is a string — numeric/boolean coercion without validation is an edge-case factory.
- Nullish access on request data and ORM results (`.first()`-style lookups whose `null` propagates).
- Edge signals: unbounded list queries without limits; file uploads without size caps; JSON body limit left at default where large payloads are expected.

## Documentation

- JSDoc/TSDoc on services and non-obvious middleware; types are documentation — `any`-typed request/response shapes are doc gaps as much as type gaps.
- API spec (OpenAPI via swagger-jsdoc/tsoa, or a committed spec file) in sync with actual mounted routes; routes absent from the spec are gaps.
- README + `.env.example` for the run/config story.
- Rationale gaps: middleware **order** (auth before routes, error handler last) is load-bearing and deserves a "why" comment; custom middleware and manual SQL without rationale.

## Maintainability and technical debt

- Complexity: fat route handlers, callback/promise/`async` style mixing, business rules inside validation schemas.
- Query health: N+1 patterns absent `include`/eager loading (Prisma/Sequelize/TypeORM); queries in loops.
- Debt markers: `// TODO`/`// FIXME`, `test.skip`/`it.skip`/`xdescribe`, `@ts-ignore`/`@ts-expect-error` clusters, deprecated dependency APIs (check against the lockfile versions).
- Duplication: repeated validation schemas or response-shaping logic that a shared helper should own; copy-pasted route boilerplate.

## Operability

- Config: env vars via a validated config module (dotenv + schema), secrets never committed; `.env` gitignored with `.env.example` present.
- Observability: a structured logger (pino/winston) with request correlation; not bare `console.log`.
- Health: a health/readiness endpoint.
- DB: migrations (Prisma/Knex/TypeORM) present, reversible, and not destructive against live data.
- Authz: auth middleware on **every** protected route or router mount; a mutation route mounted before/without the auth middleware is a blocker candidate. `helmet` and a deliberate CORS config on public APIs.
- Throttling: `express-rate-limit` (or gateway equivalent) where the contract implies limits.
- Verify runnability with a throwaway `npm ci`, `tsc --noEmit` (if TS), and a test run — never mutate the repo.
