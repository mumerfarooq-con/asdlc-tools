# Discovery Contract

The agnosticism engine. It locates, inside the target repo, the inputs that let PDQC configure itself instead of hardcoding stack knowledge. Most stack-specific knowledge should live in the repo, not in PDQC.

## What it searches for

1. **Standards docs** — coding standards, style guides, contribution rules.
2. **Architecture docs** — design docs, ADRs, module/boundary definitions.
3. **Other practice-defining docs** — anything the team treats as "how we build here."
4. **Existing sub-agent and command definitions** — so PDQC can align to the repo's own agent conventions and reuse similar ones rather than imposing its own.
5. **Convention signals** — patterns inferable directly from the code when docs are silent.

## Search order

1. Conventional locations: `docs/`, `ARCHITECTURE.md`, `CONTRIBUTING.md`, `README`, `.claude/` (or the repo's agent/command dir), and repo root.
2. Content scan: files whose content reads as standards even if unconventionally named.
3. Fall back to the stack profile only for what neither the docs nor the code establish.

## Fallback discipline (v0)

Ship discovery **with** an explicit config (`pdqc.config.example.yaml`) that names the target repo's known paths.

**Prove detection before trusting discovery.** Run the inspectors first with the explicit config so you know the findings are good when fed correct inputs. Only then let discovery run and verify it independently resolves to the same inputs. Never debug discovery and detection at the same time — you will not be able to tell which one is wrong.

## Output — resolved input manifest

Discovery emits a manifest attached to the QA report:

- which standards/architecture docs were found (and their paths),
- which conventions were derived from code,
- which stack profile was selected,
- what fell back to the profile because the repo documented nothing.

The manifest makes every finding auditable: a reader can see *why* a given rule was applied.
