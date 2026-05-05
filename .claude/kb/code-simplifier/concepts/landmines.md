# Landmines

> **Purpose**: A catalog of code/config that **looks fine** because surface validation passes — `kubectl apply` returns 0, the YAML lints, the URL opens — but silently produces nothing or the wrong thing.
> **Confidence**: 0.95
> **MCP Validated**: 2026-04-27

## Overview

Landmines are the worst kind of bug: zero error output, zero alerts, just a feature that didn't ship. They survive code review because the diff parses, the chart renders, the smoke test happens to not exercise the path. This concept catalogs the recurring shapes from this repo so you can spot them in future PRs.

The unifying pattern: **surface validation (lint, schema, HTTP 200) passes; semantic intent is silently dropped.**

## Landmine Catalog

### 1. Orphan files that look like they ship

```
deploy/
  rollouts/
    analysis-templates/
      error-rate.yaml         <-- not referenced by any chart, kustomization, or helmfile
```

`kubectl apply -f deploy/rollouts/analysis-templates/error-rate.yaml` works in a one-off. The file looks like a shipped artifact. New operators copy it as a starter and customize. None of the resulting templates are installed by `helmfile sync` because no chart references the directory.

**Detection**: `grep -r "<basename>" charts/ kustomize/ helmfile.yaml` — empty output means orphan.
**Fix (commit c97741e)**: delete the orphan; if the content is needed, fold it into a chart's `templates/`.

### 2. Two install paths drifting

```makefile
# Makefile (one path)
install-argo-rollouts:
	kubectl apply -f https://github.com/argoproj/argo-rollouts/releases/download/v2.12.0/install.yaml
```

```yaml
# deploy/argo-rollouts/kustomization.yaml (the other path)
resources:
  - https://github.com/argoproj/argo-rollouts/releases/download/v2.14.5/install.yaml
```

CI uses one path. Local dev uses the other. They worked yesterday because the API surface hadn't changed. Today an alpha field moved.

**Detection**: any pinned version literal duplicated across files.
**Fix (commit d04d47e)**: pick one as canonical; the other delegates (`make install-argo-rollouts: ; kustomize build deploy/argo-rollouts | kubectl apply -f -`).

### 3. Schema field-name drift

```python
# Schema v1
class GroundTruth(BaseModel):
    http_route: str

# Reader (still on v1 in some path)
gt.http_route

# Schema v2 (rename, intended)
class GroundTruth(BaseModel):
    http_target: str       # renamed
```

Both schemas validate. Both fields are strings. The reader on v1 sees `KeyError` only when it actually accesses the field — and if it accesses defensively (`gt.get("http_route", "")`), it gets `""` and downstream produces an "OK" result with empty content.

**Detection**: rename a field, run a full grep for the old name across the repo + dashboards + tests.
**Fix (commit c4611c9)**: temporary `gt.get("http_target") or gt.get("http_route", "")` with a dated comment, plus delete the legacy reader. See [../patterns/structured-fallback.md](../patterns/structured-fallback.md).

### 4. CamelCase Helm values that should be snake_case

Tempo's chart expects `metrics_generator` (snake_case, top-level under `tempo:`). We wrote:

```yaml
# values.yaml — wrong casing, silently ignored
tempo:
  metricsGenerator:
    enabled: true
    remoteWriteUrl: http://prometheus:9090/api/v1/write
```

`helm install` returned 0. The chart's default `metrics_generator: { enabled: false }` applied. No remote-write happened. We chased the missing metric for two days.

**Detection**: `helm template ... | grep -i 'metrics_generator\|metricsGenerator'` — confirm the key you wrote is the key the chart reads. Better: `helm get values <release> --all` post-install.
**Fix (commit cea8238)**: match the chart's casing exactly. Convention check: any key in `values.yaml` that doesn't appear verbatim in the chart's `values.yaml` default is suspect.

### 5. Legacy URL params silently rejected

Grafana 10+ ignores `queryType=traceId` in `/explore` URLs. The link still opens Explore — surface "works" — but lands on the default datasource view rather than the trace lookup.

```text
# Old (Grafana 8)
/explore?left=%7B"queryType":"traceId","query":"abc123"%7D

# Grafana 10+ silently ignores this; users see an empty Explore tab.
```

**Detection**: any hand-built Grafana URL.
**Fix (commit 7fa5219)**: use the `internal` data link spec; the schema is enforced and forward-compatible. See [../patterns/data-link-vs-url.md](../patterns/data-link-vs-url.md).

### 6. SSE generator that raises before its first yield

```python
async def stream_postmortem(incident_id: str) -> AsyncIterator[str]:
    incident = await fetch(incident_id)            # raises TypeError if shape changed
    yield f"event: ready\ndata: {json.dumps({'id': incident.id})}\n\n"
    ...
```

If `fetch()` raises before the first `yield`, FastAPI's `StreamingResponse` has already written the 200 OK headers. The client sits with an open connection, no event, no error, indefinitely (until its own timeout).

**Detection**: any `StreamingResponse` whose generator does I/O before the first yield.
**Fix (commit b695a32)**: yield a sentinel error event before any failable branch:

```python
async def stream_postmortem(incident_id: str) -> AsyncIterator[str]:
    try:
        incident = await fetch(incident_id)
    except Exception as e:
        yield f"event: error\ndata: {json.dumps({'msg': str(e)})}\n\n"
        return
    yield f"event: ready\ndata: {json.dumps({'id': incident.id})}\n\n"
    ...
```

See [error-handling-discipline.md](error-handling-discipline.md).

### 7. PromQL ratios going to "No data"

```promql
# Smell — empty numerator collapses the whole expression
sum(rate(http_requests_total{status=~"5.."}[5m]))
  / sum(rate(http_requests_total[5m]))
```

When traffic is zero, both sides are absent. The panel shows "No data." Operators read this as "monitoring broken," not "service idle." Worse: alerts using `> 0` will not fire on the empty result.

**Fix**: `or vector(0)` the numerator, `clamp_min(_, 1)` the denominator. See [../patterns/fail-loud-not-silent.md](../patterns/fail-loud-not-silent.md).

### 8. ConfigMap label drift

A dashboard ConfigMap was originally labeled `grafana_dashboard=1`. A refactor changed the label to `grafana_dashboard: "true"` (string). Grafana's sidecar matches on the original; the new ConfigMap is ignored, the old one (which still has the original label and lingers) serves stale content.

**Detection**: `kubectl get configmap -l grafana_dashboard=1` — any survivors after a deploy?
**Fix**: delete-then-apply pattern, or watch for label-set changes in PR review.

### 9. Helmfile values not actually overriding

```yaml
# helmfile.yaml
releases:
  - name: backend
    chart: ./charts/backend
    values:
      - environments/{{ .Environment.Name }}.yaml
      - secrets/{{ .Environment.Name }}.yaml      <-- file doesn't exist
```

Helmfile silently skips missing values files unless you set `missingFileHandler: Error`. The release proceeds with chart defaults. The "secret" override never applies.

**Detection**: `helmfile build | grep -A1 'name: backend' | grep values` — reconcile against ls.
**Fix**: add `missingFileHandler: Error` at the top of helmfile.yaml.

## The Common Shape

All landmines fit one template:

> *Surface check passes (lint, kubectl apply 0, HTTP 200) -> semantic intent silently dropped -> bug surfaces only when the dropped intent matters.*

When reviewing, ask: **"What does this do if the field is wrong-but-syntactically-valid?"** If the answer is "silently nothing," you've found a landmine.

## Quick Reference

| Landmine | Surface symptom | True symptom |
|----------|-----------------|--------------|
| Orphan deploy file | `kubectl apply` works ad hoc | Never installed by chart |
| Dual install paths | Both `make install` and `kustomize build` succeed | Versions drift, alpha API breaks |
| Schema field rename | Pydantic validates both old and new | Reader sees `""`, ships empty |
| Wrong Helm value casing | `helm install` exits 0 | Default applies; feature off |
| Legacy URL param | Link opens | Wrong view loaded |
| Pre-yield generator raise | 200 OK | Client hangs forever |
| PromQL ratio with empty numerator | Panel renders | "No data" forever |
| Label drift | New CM applied | Sidecar still serves old |
| Missing helmfile values file | Release succeeds | Override not applied |

## Related

- [spotting-complexity.md](spotting-complexity.md)
- [error-handling-discipline.md](error-handling-discipline.md)
- [../patterns/fail-loud-not-silent.md](../patterns/fail-loud-not-silent.md)
- [../patterns/data-link-vs-url.md](../patterns/data-link-vs-url.md)
- [../patterns/structured-fallback.md](../patterns/structured-fallback.md)
- [../index.md](../index.md)
