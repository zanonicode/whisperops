# Code Simplifier — Knowledge Base

> **MCP Validated:** 2026-04-27
> **Scope:** Practical simplification heuristics for the SRE Copilot codebase — Python (FastAPI, Pydantic, async generators), Helm charts, Helmfile, Make, and shell. Focus on **detecting unnecessary complexity** and **collapsing it** rather than reciting generic clean-code lore.

## Why This KB Exists

Across the SRE Copilot repo we keep hitting the same shape of bug:

- A function "defends" against an input case that the type system or framework already prevents.
- Two near-identical Make targets (`dashboards` and `dashboards-reset`) with subtly different semantics — users learn the wrong one and silently produce nothing.
- A YAML file that wraps a JSON file that is **also** the source of truth — both are hand-edited, they drift.
- An orphan `analysistemplate.yaml` that looks shipped but is never installed by any chart.
- An `or vector(0)` missing from a PromQL ratio, so the panel goes "No data" forever.

The pattern: **complexity hides behind the facade of working in the happy path**. This KB is the checklist for spotting it before it ships, and the playbook for collapsing it once you do.

## Contents

### Concepts (the lenses)

| File | Topic |
|------|-------|
| [concepts/spotting-complexity.md](concepts/spotting-complexity.md) | Smell checklist: defensive null-checks for trusted inputs, duplicated validation, dual install paths, hand-maintained YAML wrapping JSON, orphan files. Includes the "git log" observation pattern. |
| [concepts/the-collapse-test.md](concepts/the-collapse-test.md) | When two functions/targets/abstractions should become one. The `make dashboards` collapse worked example — and the inverse: when **not** to collapse. |
| [concepts/landmines.md](concepts/landmines.md) | Things that look like they work because surface validation passes: schema field-name drift, camelCase-vs-snake_case Helm value gotchas, legacy URL params silently rejected by newer Grafana, orphan manifests. |
| [concepts/the-yagni-test.md](concepts/the-yagni-test.md) | When to delete a feature/branch/option vs keep it. Real removals: canary moment in `make demo`, dashboards-reset, the orphan AnalysisTemplate. |
| [concepts/error-handling-discipline.md](concepts/error-handling-discipline.md) | Validate at boundaries only. Trust internal callers and framework guarantees. SSE-generator first-yield rule. |

### Patterns (the recipes)

| File | Topic |
|------|-------|
| [patterns/append-not-replace.md](patterns/append-not-replace.md) | When a write is collaborative (Python `logger.handlers`, K8s field manager, helmfile values), append. When authoritative, replace. The `configure_logging` OTel-handler-wipe bug. |
| [patterns/single-source-of-truth.md](patterns/single-source-of-truth.md) | JSON source / YAML generated / Make target applies. The `regen-configmaps.py` worked example. |
| [patterns/conditional-helm-templates.md](patterns/conditional-helm-templates.md) | One chart producing either a Deployment OR a Rollout, with HPA `scaleTargetRef.kind` switching accordingly. Don't fork the chart. |
| [patterns/fail-loud-not-silent.md](patterns/fail-loud-not-silent.md) | `or vector(0)`, `clamp_min`, `noValue: "0"`, raising vs returning empty. |
| [patterns/data-link-vs-url.md](patterns/data-link-vs-url.md) | Grafana internal data links vs hand-crafted `/explore?panes={...}`. Prefer framework URL construction over string concatenation. |
| [patterns/structured-fallback.md](patterns/structured-fallback.md) | `gt.get("log_payload") or gt.get("log_snippet", "")` — accept multiple field names during a schema migration, **with** a comment. |
| [patterns/idempotent-make-targets.md](patterns/idempotent-make-targets.md) | `mkdir -p`, `kubectl create --dry-run=client -o yaml \| kubectl apply -f -`, marker files, retry-loops for flaky pulls. |

## Quick Reference

- [quick-reference.md](quick-reference.md) — 25 simplifier triggers in a single skim-friendly table.

## Key Principles

| Principle | Description |
|-----------|-------------|
| **Collapse the fast path into the slow path** | If users need to know about both, the fast path isn't worth the cognitive cost. |
| **Trust your boundaries** | Validate at the edge (HTTP body, env vars). Don't re-validate inside trusted code paths. |
| **One source of truth** | If two artifacts represent the same data, one must be **generated** from the other. |
| **Fail loud at the producer, not at the consumer** | An empty PromQL result is not "no data" — it's a bug; encode the zero. |
| **Append when collaborative, replace when authoritative** | The default global logger has handlers from frameworks. Don't `logger.handlers = [...]`. |
| **Delete is a feature** | Removing the orphan AnalysisTemplate file made the chart simpler **and** more correct. |

## Learning Path

| Level | Files |
|-------|-------|
| **Beginner** | [concepts/spotting-complexity.md](concepts/spotting-complexity.md), [quick-reference.md](quick-reference.md) |
| **Intermediate** | [concepts/the-collapse-test.md](concepts/the-collapse-test.md), [patterns/append-not-replace.md](patterns/append-not-replace.md), [patterns/single-source-of-truth.md](patterns/single-source-of-truth.md) |
| **Advanced** | [concepts/landmines.md](concepts/landmines.md), [patterns/conditional-helm-templates.md](patterns/conditional-helm-templates.md), [patterns/fail-loud-not-silent.md](patterns/fail-loud-not-silent.md) |

## Agent Usage

| Agent | Primary Files | Use Case |
|-------|---------------|----------|
| code-reviewer | All concepts | Flag complexity smells in PR diffs |
| refactor | concepts/the-collapse-test.md, patterns/* | Propose collapses & rewrites |
| sre-copilot-builder | concepts/landmines.md | Avoid known foot-guns when authoring charts/dashboards |

## Related KBs

- [helm-helmfile](../helm-helmfile/index.md) — chart authoring; landmines section here references its conventions
- [otel-lgtm](../otel-lgtm/index.md) — PromQL/Loki examples behind `fail-loud-not-silent`
- [argo-rollouts](../argo-rollouts/index.md) — the AnalysisTemplate-orphan example
- [fastapi-lambda](../fastapi-lambda/index.md) — boundary-validation discipline overlaps
