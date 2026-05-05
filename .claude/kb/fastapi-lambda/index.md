# FastAPI + Mangum on AWS Lambda — Knowledge Base

> **MCP Validated:** 2026-04-23
> **Scope:** Backend search aggregator — FastAPI app wrapped by Mangum, deployed as a single AWS Lambda behind API Gateway, fanning out async `httpx` calls to 3 sources (ADO wiki via SQLite FTS5, MediaWiki, Discourse).

## Why This Stack

| Need | Choice | Rationale |
|------|--------|-----------|
| HTTP routing + OpenAPI | **FastAPI** | Async-native, Pydantic-v2 integrated, free docs |
| Lambda adapter | **Mangum** | ASGI-to-API-GW shim, maintained, zero-config |
| Observability | **AWS Lambda Powertools** | Official AWS lib — `@logger` / `@tracer` / `@metrics` decorators, correlation IDs, EMF metrics |
| Validation | **Pydantic v2** | Schema-driven request/response; auto-generates OpenAPI |
| Parallel fan-out | **`httpx.AsyncClient` + `asyncio.gather`** | Three sources queried concurrently in one Lambda invocation |

## Decision Rationale

- **Single Lambda** (not microservices): <100 concurrent users, one endpoint (`/search`), cost-optimized.
- **FastAPI over vanilla Powertools routing:** free Pydantic validation + OpenAPI docs outweigh the ~150 ms cold-start cost of FastAPI imports.
- **Mangum over AWS-Lambda-Web-Adapter:** pure-Python, no extra runtime layer, battle-tested for API GW v1 + v2 events.
- **Read-only Lambda:** index is built by a separate scheduled Lambda (see `sqlite-fts5/patterns/lambda-persistence.md`).

## Contents

### Concepts (what & why)

| File | Topic |
|------|-------|
| [concepts/mangum-adapter.md](concepts/mangum-adapter.md) | How Mangum translates API GW events to ASGI scope |
| [concepts/cold-start-mitigation.md](concepts/cold-start-mitigation.md) | Lazy imports, SnapStart, provisioned concurrency, `/tmp` reuse |
| [concepts/powertools-integration.md](concepts/powertools-integration.md) | Logger/tracer/metrics decorators, correlation IDs, structured JSON |

### Patterns (copy-paste recipes)

| File | Topic |
|------|-------|
| [patterns/aggregator-handler.md](patterns/aggregator-handler.md) | `/search` endpoint fanning out to 3 sources via `asyncio.gather` |
| [patterns/pydantic-schemas.md](patterns/pydantic-schemas.md) | Request/response models (`SearchRequest`, `SearchHit`, `SearchResponse`) |
| [patterns/error-handling.md](patterns/error-handling.md) | Per-source timeouts, partial-success responses, standardized error shape |

## Quick Start

```python
# app.py — minimum viable Lambda handler
from aws_lambda_powertools import Logger, Metrics, Tracer
from fastapi import FastAPI
from mangum import Mangum

logger = Logger()
tracer = Tracer()
metrics = Metrics(namespace="DevOpsWikiSearch")

app = FastAPI(title="DevOps Wiki Search")

@app.get("/health")
async def health() -> dict[str, str]:
    return {"status": "ok"}

_asgi = Mangum(app, lifespan="off")

@logger.inject_lambda_context(correlation_id_path="requestContext.requestId")
@tracer.capture_lambda_handler
@metrics.log_metrics(capture_cold_start_metric=True)
def handler(event, context):
    return _asgi(event, context)
```

## Performance Targets

| Metric | Target | Source |
|--------|--------|--------|
| Cold start (P95) | < 1.5 s | Powertools `ColdStart` metric |
| Warm latency (P95) | < 800 ms | API GW `IntegrationLatency` |
| End-to-end search (P95) | < 2 s | project NFR |

## Related KBs

- [sqlite-fts5](../sqlite-fts5/index.md) — local index queried by the handler
- `python-httpx-async` (upcoming) — parallel source fan-out details
- `aws-serverless-web` (upcoming) — packaging, layers, API GW config
- `microsoft-sso` (upcoming) — token validation on this Lambda
