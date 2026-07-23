# Stack Profile: React SPA (+ TypeScript)

**Profiles are the only stack-specific artifacts in PDQC.** Each is external and swappable. It tells inspectors *how* the universal principles manifest in a React frontend — it is never the source of a principle. Adding a new stack means writing a sibling profile with the same section headings; the inspectors and rubric do not change.

Everything below is a **detection heuristic**, not a rule. The rule always comes from the repo's own standards docs or its dominant observed convention. Where this profile and the repo's docs disagree, the docs win. For a frontend, the "public contract" is two-sided: the API boundary it consumes and the component/prop surface it exposes.

## Contract and consistency

- API boundary: one centralized client (fetch wrapper, axios instance, or generated client) owning base URL, auth headers, and error normalization — scattered raw `fetch` calls are the drift signal.
- API types: response/request shapes typed (hand-written interfaces or generated from the backend schema) and used at the call site; `any`-typed API data breaks the contract chain.
- Routing: the route table (react-router or framework equivalent) enumerable from one place; orphan routes and dead links are deviations.
- One state/data convention: server state via one library (React Query/SWR/RTK Query) and client state via one mechanism — three coexisting patterns for the same job is the consistency finding.
- Component contract: props typed, shared UI going through the design-system/common components rather than one-off styled clones.

## Error and edge handling

- Error boundaries wrap route-level trees; a thrown render error white-screening the whole app is the baseline failure.
- Every data fetch handles its **loading, error, and empty** states — the happy-path-only component is this stack's signature defect.
- Effect hygiene: `useEffect` cleanup for subscriptions/timers/aborts; stale-closure and race conditions on fast-changing inputs (unaborted fetches applying out of order).
- Forms: validation before submit, disabled/duplicate-submit protection, server error surfaced to the user.
- Edge signals: lists without keys or with index keys under reorder; unguarded deep property access on API data; timezone/locale assumptions in date rendering.

## Documentation

- Non-obvious components and hooks carry a doc comment (or a Storybook story where the repo uses one); types are the primary documentation — keep them honest.
- README covers the run story: node version, install, dev server, build, and **every** required env var (`VITE_*`/`NEXT_PUBLIC_*` etc.) with an example file.
- Rationale gaps: memoization (`useMemo`/`useCallback`/`memo`), manual `useEffect` orchestration, and eslint-disable lines without a "why" comment.

## Maintainability and technical debt

- Complexity: components mixing data fetching, business logic, and layout; extract-hook candidates; prop drilling through 3+ levels where context/composition fits.
- `useEffect` misuse: deriving state that should be computed during render; effect chains that re-implement a data library.
- Debt markers: `// TODO`/`// FIXME`, `test.skip`, `@ts-ignore` clusters, dead components and unused exports, deprecated lifecycle patterns and legacy class components in a hooks codebase.
- Duplication: near-identical components/hooks that a shared abstraction should own; repeated inline style/tailwind blobs that belong in the design system.

## Operability

- Config: API base URLs and feature flags from build-time env vars, never hardcoded. **Nothing secret ships in the bundle** — any private key/token in frontend source or env is a blocker, full stop.
- Observability: an error-reporting hook (Sentry or equivalent) wired to boundaries and the API client; not bare `console.log`.
- Production readiness: the build succeeds clean; debug flags, mock handlers (MSW), and verbose logging excluded from the prod bundle.
- Accessibility floor: interactive elements are real buttons/links, forms have labels, images have alt text — a11y regressions are production defects, not polish.
- Bundle hygiene: no accidental megabyte dependencies; route-level code splitting where the repo's size warrants it.
- Verify runnability with a throwaway `npm ci`, a production build, and a test run — never mutate the repo.
