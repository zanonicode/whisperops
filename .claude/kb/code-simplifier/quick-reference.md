# Code Simplifier Quick Reference

> **MCP Validated:** 2026-04-27
> Skim this list when reviewing a diff, authoring a chart, or writing a Make target. Each row: **smell** -> **replacement** -> **rule of thumb**. Drill into [concepts/](concepts/) and [patterns/](patterns/) for the worked examples.

## Simplifier Triggers

| #  | Smell (what you see) | Replacement (what to do) | Rule of thumb |
|----|----------------------|--------------------------|---------------|
| 1  | `x = [item]; x.append(other)` | `x = [item, other]` | If you know the elements at construction time, build the literal. |
| 2  | `if x is None: x = []` then `x.append(...)` | `x = [...]` directly, or `x = x or []` once at the boundary | Defaults belong at the edge, not at every callsite. |
| 3  | `try: foo() except Exception: pass` | Let it raise, or catch the **specific** exception with a logged reason | Bare-except hides the bug you'll spend a day finding. |
| 4  | `logger.handlers = [my_handler]` in app code | `logger.addHandler(my_handler)` | Root logger is collaborative — see [patterns/append-not-replace.md](patterns/append-not-replace.md). |
| 5  | Two Make targets, one "fast" and one "reset/full" | Collapse into one always-correct target | If users need to know about both, the fast path isn't worth it. See `make dashboards` collapse. |
| 6  | YAML file hand-edited next to a JSON file containing the same keys | Generate the YAML from the JSON via a `regen-*` Make target | Two sources of truth = drift = silent bug. See [patterns/single-source-of-truth.md](patterns/single-source-of-truth.md). |
| 7  | Validation in middleware **and** the endpoint body | Pick one layer (boundary), delete the other | Trust the boundary. See [concepts/error-handling-discipline.md](concepts/error-handling-discipline.md). |
| 8  | `or vector(0)` missing on a PromQL ratio | Append `or vector(0)` to the numerator | "No data" panels are bugs, not absence. See [patterns/fail-loud-not-silent.md](patterns/fail-loud-not-silent.md). |
| 9  | `clamp_min(rate(...), 0)` wrapping a counter | Delete the clamp on counters; only divide-by-zero needs `clamp_min` on the **denominator** | Counters never go negative; you're hiding a real bug. |
| 10 | Stat panel shows "No data" for absent series | Set `noValue: "0"` on the panel options | Operator brain reads "No data" as "broken pipeline." Encode the zero explicitly. |
| 11 | Hand-crafted `/explore?panes={...}` URL string in a dashboard JSON | Use Grafana's `internal` data link with `datasource` + `query` keys | See [patterns/data-link-vs-url.md](patterns/data-link-vs-url.md). The `queryType=traceId` legacy param is silently dropped. |
| 12 | Two install paths (Makefile pinned vX, kustomize pinned vY) | One install path; the other points at it | Drift between two installers is a class-of-bug. Commit d04d47e. |
| 13 | Orphan manifest in `deploy/...` not referenced by any chart or kustomization | Delete the file | If nothing applies it, it doesn't ship. Commit c97741e. |
| 14 | Helm values file with `metricsGenerator:` (camelCase) for a chart that expects `metrics_generator:` | Match the upstream chart's casing exactly | Wrong casing = silently ignored, default applied. Tempo case, commit cea8238. |
| 15 | Schema field renamed but reader still uses old name | Use `gt.get("new") or gt.get("old", default)` for the migration window, comment the cutoff | See [patterns/structured-fallback.md](patterns/structured-fallback.md). |
| 16 | Two charts: `backend` and `backend-rollout` | One chart with `{{- if .Values.useArgoRollouts }}` switching kind | Don't fork on a boolean. See [patterns/conditional-helm-templates.md](patterns/conditional-helm-templates.md). |
| 17 | HPA hard-coded to `kind: Deployment` next to a chart that can render Rollouts | `scaleTargetRef.kind: {{ if .Values.useArgoRollouts }}Rollout{{ else }}Deployment{{ end }}` | Track the workload your chart actually produces. |
| 18 | SSE generator that may raise before its first `yield` | Yield a sentinel error event before any branch can fail | Clients hang forever otherwise. See `postmortem.py` TypeError, commit b695a32. |
| 19 | `make demo` plus `make demo-canary` plus `make demo-rollback` | Keep these — different blast radius / intent | Inverse of the collapse rule. See [concepts/the-collapse-test.md](concepts/the-collapse-test.md). |
| 20 | `mkdir foo/` in a Make recipe without `-p` | `mkdir -p foo/` | Re-running the target should always succeed. See [patterns/idempotent-make-targets.md](patterns/idempotent-make-targets.md). |
| 21 | `kubectl create -f x.yaml` in a Make recipe | `kubectl create -f x.yaml --dry-run=client -o yaml \| kubectl apply -f -` | `apply` is idempotent; `create` is not. |
| 22 | `ollama pull mymodel` in a recipe that fails on flaky network | `until ollama pull mymodel; do sleep 5; done` | Bake retries into the recipe, not the runbook. |
| 23 | Defensive `if not isinstance(payload, dict): raise` inside a Pydantic-validated handler | Delete the check | Pydantic already enforced it at the boundary. |
| 24 | `Optional[str]` parameter that's never `None` in any caller | Drop the `Optional`, drop the `if x is None` branch | Type lies are worse than missing types. |
| 25 | A feature behind a flag that nobody flips | Delete the flag and the dead branch | See [concepts/the-yagni-test.md](concepts/the-yagni-test.md). |
| 26 | A `# TODO: remove after migration` from > 6 months ago | Remove it, or convert to a tracked ticket and re-date | Stale TODOs become permanent debt. |
| 27 | Two helmfile environments differing in 1 field | One environment, one templated value | Forking environments scales linearly with N envs. |
| 28 | Logging configuration replacing `logger.handlers` at startup | Append your handler; only call `dictConfig` once at the boundary | Frameworks (Lambda, OTel autoinstrument) attach handlers before your `main()` runs. |
| 29 | `cmd | true` to ignore exit code | `cmd || echo "non-fatal: $?"` with an explicit reason | Hiding non-zero exits hides bugs. |
| 30 | "Will be reused later" abstraction with one caller | Inline it; reabstract when the second caller appears | Rule of three. The cost of the wrong abstraction > the cost of duplication. |

## Decision Matrix

| Situation | Choose |
|-----------|--------|
| Two functions with subtly different semantics | Collapse, or rename both to make the difference loud |
| One source of truth + N derived files | Generate; never hand-edit derived |
| Internal call after Pydantic validation | Trust the type; no re-check |
| External input or env var | Validate at the boundary, exactly once |
| PromQL panel showing rate/ratio | Always `or vector(0)` the numerator and `clamp_min` the denominator |
| Grafana cross-datasource link | `internal` data link, never URL string-build |
| Make target that creates files | `mkdir -p`, `--dry-run \| apply`, idempotent always |

## Common Pitfalls

| Don't | Do |
|-------|-----|
| Replace `logger.handlers` | `logger.addHandler(...)` |
| Hand-edit a YAML next to its JSON source | Run `make regen-configmaps` |
| Leave orphan manifests in `deploy/` | Delete them |
| Wrap counters in `clamp_min` | Only clamp denominators |
| Build Grafana URLs with f-strings | Use `internal` data link spec |
| Add `Optional[X]` for fields you never null | Make it required, delete the branch |

## Related Documentation

| Topic | Path |
|-------|------|
| Spotting smells | [concepts/spotting-complexity.md](concepts/spotting-complexity.md) |
| When to collapse | [concepts/the-collapse-test.md](concepts/the-collapse-test.md) |
| Things that look fine but aren't | [concepts/landmines.md](concepts/landmines.md) |
| When to delete | [concepts/the-yagni-test.md](concepts/the-yagni-test.md) |
| Boundary validation | [concepts/error-handling-discipline.md](concepts/error-handling-discipline.md) |
| Full Index | [index.md](index.md) |
