# Append, Not Replace

> **Purpose**: Distinguish writes that are *collaborative* (other systems also write here; you must coexist) from writes that are *authoritative* (you own this; replace is correct). Replacing a collaborative resource silently removes other writers' contributions.
> **MCP Validated**: 2026-04-27

## When to Use

- You're configuring the **root logger** in a Python app that runs under Lambda, FastAPI, OTel autoinstrument, or any framework that may attach handlers before your code runs.
- You're updating a Kubernetes resource that has fields managed by other field-managers (HPA scaling replicas, controllers patching status).
- You're adding values to a helmfile release that already has values from other layers (environment file, secret file, base file).
- Any time the resource has a "list of contributors" semantic.

## When NOT to Use

- You explicitly own the entire resource (your own ConfigMap that no controller patches).
- You are doing a full reset on purpose (test setup, migration cutover) — make the intent loud in the function name (`reset_logging` not `configure_logging`).
- The resource is a value, not a collection (a scalar config field).

## The Distinction

| Write style | Use when... | API shape |
|-------------|-------------|-----------|
| **Replace** | You own the entire resource | `x.handlers = [h]`, `kubectl apply` (3-way merge), `release.values = [v]` |
| **Append** | You share the resource | `x.addHandler(h)`, server-side apply with field-manager, `release.values += [v]` |

The cost of replacing a collaborative resource is high and silent. The cost of appending an authoritative resource is low (an extra entry that gets reconciled).

## Implementation

### Python: configure_logging done wrong, then right (commit 361b312)

```python
# scripts/configure_logging.py — BEFORE (regressed)
import logging
import sys

def configure_logging() -> None:
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(name)s %(message)s"))
    root = logging.getLogger()
    root.handlers = [handler]               # <-- wipes the OTel handler attached by autoinstrument
    root.setLevel(logging.INFO)
```

Symptom: structured logs continued to print to stdout, but the OpenTelemetry collector handler that was supposed to ship logs to Loki was gone. The team didn't notice for two weeks because dashboards "had data" — they just didn't have *application* logs, only ingress logs.

```python
# scripts/configure_logging.py — AFTER
import logging
import sys
from typing import Iterable

_APP_HANDLER_NAME = "sre-copilot-app"

def configure_logging() -> None:
    """Attach our app handler to the root logger. Idempotent.

    Collaborative write: other handlers (OTel autoinstrument, Lambda
    runtime) MUST survive. Never reassign root.handlers.
    """
    root = logging.getLogger()
    root.setLevel(logging.INFO)

    # Idempotent: skip if our handler is already attached (re-entrant init).
    if _has_handler_named(root.handlers, _APP_HANDLER_NAME):
        return

    handler = logging.StreamHandler(sys.stdout)
    handler.set_name(_APP_HANDLER_NAME)
    handler.setFormatter(logging.Formatter(
        "%(asctime)s %(levelname)s %(name)s %(message)s"
    ))
    root.addHandler(handler)                # collaborative

def _has_handler_named(handlers: Iterable[logging.Handler], name: str) -> bool:
    return any(h.get_name() == name for h in handlers)
```

Three things changed:
1. `root.handlers = [...]` -> `root.addHandler(...)`.
2. The handler is named, so re-entrant init is idempotent.
3. The function comment names the rule explicitly.

### Kubernetes: server-side apply with field manager

```bash
# Wrong — client-side apply with strategic merge can clobber controller fields
kubectl apply -f deployment.yaml

# Right — server-side apply, named manager, only owns fields you set
kubectl apply -f deployment.yaml --server-side --field-manager=sre-copilot-deployer
```

The HPA controller owns `spec.replicas`. Server-side apply with a distinct field manager means your apply doesn't fight the HPA's writes.

### Helmfile: layered values

```yaml
# Right — append, do not replace
releases:
  - name: backend
    chart: ./charts/backend
    values:
      - environments/{{ .Environment.Name }}.yaml      # base
      - secrets/{{ .Environment.Name }}.yaml           # appended
      - { image: { tag: "{{ env "TAG" }}" } }          # appended; overrides on conflict only
```

Helmfile merges values lists in order; later entries win on conflict. The order is the policy. Don't `set:` over the top of `values:` unless you mean to authoritatively override.

## Configuration

| Setting | Default | Description |
|---------|---------|-------------|
| `logger handler `.set_name(...)` | none | Required for idempotent re-init detection |
| `--server-side --field-manager=NAME` | client-side | Required for collaborative kubectl apply |
| `helmfile values:` order | first-to-last, last wins | Layer order is the policy |

## Example Usage

```python
# At app startup (e.g., FastAPI lifespan, Lambda init)
from scripts.configure_logging import configure_logging

configure_logging()    # safe to call multiple times; appends only
```

```bash
# CI deploy step
kubectl apply -f charts/backend/rendered.yaml \
    --server-side --field-manager=ci-deployer
```

## Anti-Pattern

```python
# Replacing handlers because "we want clean output"
logging.basicConfig(format="...", level=logging.INFO, force=True)
# force=True calls root.handlers.clear() — same bug, different API.
```

If you need clean output, format your handler. Don't burn the others' handlers down to do it.

```bash
# Replacing the resource and re-creating it during a normal deploy
kubectl delete -f charts/backend/rendered.yaml
kubectl apply  -f charts/backend/rendered.yaml
# Drops fields managed by HPA, controllers, webhooks. Use only for true reset flows.
```

## See Also

- [single-source-of-truth.md](single-source-of-truth.md)
- [idempotent-make-targets.md](idempotent-make-targets.md)
- [../concepts/spotting-complexity.md](../concepts/spotting-complexity.md)
- [../concepts/error-handling-discipline.md](../concepts/error-handling-discipline.md)
- [../index.md](../index.md)
