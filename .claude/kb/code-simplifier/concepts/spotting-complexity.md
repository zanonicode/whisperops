# Spotting Complexity

> **Purpose**: A checklist of complexity smells in Python, Helm, Make, and Grafana code — and an observational technique (read git log) for finding the smells your eyes have learned to skip over.
> **Confidence**: 0.95
> **MCP Validated**: 2026-04-27

## Overview

Complexity rarely arrives as a single bad commit. It accumulates one defensive `if`, one duplicated validator, one orphan YAML file at a time. Each addition was rational in isolation. The aggregate is a codebase where the happy path works and the unhappy path produces silent failure modes that take an afternoon to diagnose.

This concept gives you the **smell checklist** for spotting complexity in a diff or during a refactor pass, plus the **observation pattern** for finding aged complexity that visual review will miss.

## The Smell Checklist

### 1. Defensive null-checks for trusted inputs

A handler that has just been validated by Pydantic should not re-check that its body is a dict. The framework already enforces it. Each redundant check is a lie about what can happen.

```python
# Smell
async def handle(request: PostmortemRequest) -> Response:
    if not isinstance(request, PostmortemRequest):  # Pydantic already enforced
        raise TypeError("invalid request")
    if request.incident_id is None:                 # Field is required: NonNull
        raise ValueError("missing incident_id")
    ...

# Clean
async def handle(request: PostmortemRequest) -> Response:
    # Pydantic guarantees both invariants. Trust the boundary.
    ...
```

### 2. Validation duplicated in middleware AND endpoint

If FastAPI middleware checks the auth header and every endpoint also checks it, you have two implementations. They will drift. The second one to be updated will be the wrong one.

```python
# Smell: middleware validates Bearer; endpoint also re-parses the header
@app.middleware("http")
async def auth_mw(request, call_next):
    if not request.headers.get("authorization", "").startswith("Bearer "):
        return JSONResponse(401, ...)
    ...

@app.post("/postmortem")
async def postmortem(req: Request, body: PostmortemRequest):
    token = req.headers["authorization"].split()[1]   # already-validated; redundant parse
    ...
```

Pick one layer. Boundary validation belongs in middleware; handler trusts the result via dependency injection (e.g., `Depends(get_current_user)`).

### 3. Two install paths

```makefile
# Smell: Makefile pins one version, kustomization pins another
install-rollouts:
	kubectl apply -f https://github.com/argoproj/argo-rollouts/releases/download/v2.12.0/install.yaml

# deploy/argo-rollouts/kustomization.yaml
resources:
  - https://github.com/argoproj/argo-rollouts/releases/download/v2.14.5/install.yaml
```

These will drift the next time someone bumps one and not the other (commit d04d47e in this repo). Pick one, have the other reference it.

### 4. Hand-maintained YAML wrapping a JSON source-of-truth

Grafana dashboards live as JSON. If you embed them into a Helm chart by hand-typing the YAML wrapper, you now have two sources. The fix is a generator (commit 8adea5e):

```python
# scripts/regen-configmaps.py
for dashboard_json in DASHBOARD_DIR.glob("*.json"):
    rendered = render_configmap_yaml(dashboard_json)
    (CHART_DIR / "templates" / f"{dashboard_json.stem}.yaml").write_text(rendered)
```

See [patterns/single-source-of-truth.md](../patterns/single-source-of-truth.md).

### 5. Orphan files

A file in `deploy/rollouts/analysis-templates/error-rate.yaml` that is referenced by zero kustomizations and zero charts looks shipped. It isn't. Operators copy it as a template and end up with the field names that **almost-but-don't** match what their controller expects.

```bash
# Find orphans
git ls-files 'deploy/**' | while read f; do
  base=$(basename "$f")
  if ! grep -rq "$base" charts/ kustomize/ helmfile.yaml; then
    echo "orphan: $f"
  fi
done
```

Commit c97741e in this repo deleted such an orphan. The chart got simpler and more correct.

### 6. Two Make targets where one would do

```makefile
# Smell
dashboards:        ## fast path — uses kubectl apply
	kubectl apply -f charts/dashboards/

dashboards-reset:  ## slow path — deletes and re-creates
	kubectl delete -f charts/dashboards/ || true
	kubectl apply -f charts/dashboards/
```

If users need to know about `dashboards-reset` because `dashboards` silently fails on certain edits (immutable fields, configmap label drift), the fast path isn't worth it. Collapse into one. See [the-collapse-test.md](the-collapse-test.md) and the commit pair `31c6a0c -> a27f67f`.

### 7. Optional flags nothing uses

```python
# Smell: kept "for future flexibility"
def render_postmortem(incident_id: str, *, dry_run: bool = False, verbose: bool = False) -> str:
    if dry_run:
        ...   # last touched 14 months ago, never set True in production
```

Delete the parameter. Its second user is hypothetical. See [the-yagni-test.md](the-yagni-test.md).

### 8. Configuration replacing what frameworks set

`logging.basicConfig(...)` and `logger.handlers = [my_handler]` both clobber handlers attached by frameworks (Lambda runtime, OTel autoinstrument). The OTel handler that was supposed to ship logs to the collector is gone, you don't notice for two weeks, and your incident dashboards are missing context. See [patterns/append-not-replace.md](../patterns/append-not-replace.md) and the `configure_logging()` regression in commit 361b312.

### 9. Camel/snake casing mismatches in Helm values

```yaml
# Smell: chart expects metrics_generator (snake_case); we wrote camelCase
tempo:
  metricsGenerator:
    enabled: true        # silently ignored — chart default applies
```

Wrong casing on a Helm value is a no-op. The chart's default applies. The metric you wanted shipped doesn't ship. See [landmines.md](landmines.md) and commit cea8238.

### 10. Legacy URL params silently rejected

Grafana's `/explore?panes={...}&queryType=traceId` honors `panes` and silently ignores `queryType` post-v10. The link "works" — it opens Explore — but doesn't do the trace lookup. See commit 7fa5219 and [patterns/data-link-vs-url.md](../patterns/data-link-vs-url.md).

## The Observation Pattern: Read git log

Visual code review trains you to skip the parts you've seen before. The smells in well-aged files are exactly the ones your eye glides over. Use git history to find them:

```bash
# How many recent commits touched this area to fix bugs the structure invited?
git log --since=6.months --oneline -- scripts/configure_logging.py
git log --since=6.months --oneline -- helm/backend/templates/

# Files with the most fix-shaped commits
git log --since=6.months --oneline --grep='^fix\|hotfix\|revert' --format='%H' \
  | xargs -n1 git show --name-only --format= \
  | sort | uniq -c | sort -rn | head -20
```

Heuristic: **a file with 4+ "fix" commits in 6 months is structurally inviting bugs**. Don't add the fifth fix. Refactor.

Real signals from this repo:
- `scripts/configure_logging.py` — handler-replacement bug (361b312)
- `scripts/regen-configmaps.py` — was missing; drift bugs accumulated until 8adea5e introduced it
- `helm/backend/templates/rollout.yaml` and `deployment.yaml` — kept diverging until conditional collapse
- `Makefile` `dashboards` family — bugs around fast/slow path (31c6a0c -> a27f67f)

## Quick Reference

| Smell | First action |
|-------|--------------|
| Defensive check for invariant | Delete the check |
| Two install paths | Pick one, alias the other |
| Hand-maintained YAML next to JSON | Write a generator |
| Orphan deploy/ file | Delete |
| Two Make targets, one "reset" | Collapse |
| Unused flag/param | Delete |
| `logger.handlers = [...]` | `logger.addHandler(...)` |
| Wrong casing in values | Match upstream chart exactly |
| Hand-built Grafana URL | `internal` data link |
| File with many recent fix commits | Refactor, don't patch |

## Common Mistakes

### Wrong: patching the symptom

```python
# A user reported the OTel handler is missing again.
# "Fix": add the handler back, manually, after configure_logging.
configure_logging()
logging.getLogger().addHandler(otel_handler)   # band-aid
```

### Correct: fix the structure

```python
# configure_logging() now appends; never replaces.
def configure_logging() -> None:
    handler = make_app_handler()
    logging.getLogger().addHandler(handler)    # collaborative write
```

## Related

- [the-collapse-test.md](the-collapse-test.md)
- [landmines.md](landmines.md)
- [the-yagni-test.md](the-yagni-test.md)
- [error-handling-discipline.md](error-handling-discipline.md)
- [../patterns/append-not-replace.md](../patterns/append-not-replace.md)
- [../patterns/single-source-of-truth.md](../patterns/single-source-of-truth.md)
- [../index.md](../index.md)
