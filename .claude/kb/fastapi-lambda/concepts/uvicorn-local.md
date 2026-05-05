# Uvicorn-Local Entry Point (Prototype)

> **Purpose:** The laptop-local Docker prototype runs the same FastAPI `app` under Uvicorn — with NO Mangum import on the code path. Enforces PC-003 from [notes/02-local-docker-prototype.md](../../../../notes/02-local-docker-prototype.md).
> **Confidence:** 0.95
> **MCP Validated:** 2026-04-24

## Overview

The prototype must port to AWS Lambda without rewrites. That means the FastAPI app — middleware, routes, dependency graph — is one artifact. Mangum and Uvicorn are two *entry points* that wrap it. They live in separate modules so the local container never imports Lambda-only code.

```text
                     ┌──────────────────┐
                     │  app/main.py     │   ← FastAPI app object (shared)
                     │    app = FastAPI │
                     │    routes,       │
                     │    middleware,   │
                     │    deps          │
                     └────────┬─────────┘
                              │
             ┌────────────────┴────────────────┐
             │                                 │
   ┌─────────▼─────────┐             ┌─────────▼──────────┐
   │ app/main.py as    │             │ app/lambda_        │
   │ Uvicorn target    │             │   handler.py       │
   │ (local container) │             │ from main import  │
   │                   │             │ app; Mangum(app)  │
   └───────────────────┘             └────────────────────┘
```

## Module Layout

```
backend/
├── pyproject.toml
├── app/
│   ├── __init__.py
│   ├── main.py            # FastAPI app — NO Mangum import
│   ├── lambda_handler.py  # Lambda-only — imports Mangum + app
│   ├── routes/
│   │   └── search.py
│   ├── deps.py
│   └── settings.py
```

## `app/main.py` — Shared

```python
import os
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from app.routes.search import router as search_router

app = FastAPI(title="DevOps Wiki Search")

allowed = [o.strip() for o in os.environ.get("CORS_ALLOW_ORIGIN", "").split(",") if o.strip()]
app.add_middleware(
    CORSMiddleware,
    allow_origins=allowed,
    allow_credentials=True,
    allow_methods=["GET", "OPTIONS"],
    allow_headers=["authorization", "content-type", "x-request-id"],
)

app.include_router(search_router)

@app.get("/health")
async def health() -> dict[str, str]:
    return {"status": "ok"}
```

## `app/lambda_handler.py` — Lambda Only

```python
from aws_lambda_powertools import Logger, Metrics, Tracer
from mangum import Mangum
from app.main import app

logger = Logger()
tracer = Tracer()
metrics = Metrics(namespace="DevOpsWikiSearch")

_asgi = Mangum(app, lifespan="off")

@logger.inject_lambda_context(correlation_id_path="requestContext.requestId")
@tracer.capture_lambda_handler
@metrics.log_metrics(capture_cold_start_metric=True)
def handler(event, context):
    return _asgi(event, context)
```

## The Two Entry Points

| Runtime | Command | Module imported | Notes |
|---------|---------|-----------------|-------|
| Local (Docker) | `uvicorn app.main:app --host 0.0.0.0 --port 8000 --reload` | `app.main` only | Mangum is never imported |
| AWS Lambda | handler: `app.lambda_handler.handler` | `app.lambda_handler` (which imports `app.main.app`) | Mangum wraps at runtime |

## Enforcement (PC-003 Smoke Test)

The compose file includes a verification command:

```bash
docker compose run --rm backend python -c \
  "from app.lambda_handler import handler; from app.main import app; print('ok')"
```

- If this passes, both paths resolve cleanly.
- If this fails with `ModuleNotFoundError: mangum` in the *Uvicorn* path, someone added `import mangum` to `main.py`. Revert.

## Why This Matters

Without this split, the local container either:

- Installs Mangum needlessly (bloats image, confuses readers), or
- Doesn't install Mangum and breaks Lambda packaging silently, or
- Imports Mangum at `main.py` top-level — which then fails if the AWS SDK context isn't present.

The split is mechanical. PC-003 is the contract.

## Common Mistakes

### Wrong

```python
# app/main.py
from mangum import Mangum
from fastapi import FastAPI
app = FastAPI()
handler = Mangum(app)    # Mangum in the shared module — violates PC-003
```

### Correct

```python
# app/main.py
from fastapi import FastAPI
app = FastAPI()

# app/lambda_handler.py (separate file)
from mangum import Mangum
from app.main import app
handler = Mangum(app)
```

## Related

- [mangum-adapter](mangum-adapter.md)
- [cold-start-mitigation](cold-start-mitigation.md)
- [../../docker-compose-local-dev/patterns/three-service-compose.md](../../docker-compose-local-dev/patterns/three-service-compose.md)
- [../../docker-compose-local-dev/patterns/compose-cors.md](../../docker-compose-local-dev/patterns/compose-cors.md)
