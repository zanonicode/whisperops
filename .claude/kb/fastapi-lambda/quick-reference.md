# FastAPI + Mangum Quick Reference

> Python 3.12 on AWS Lambda. Copy-paste snippets.

## Handler Skeleton

```python
from aws_lambda_powertools import Logger, Metrics, Tracer
from fastapi import FastAPI
from mangum import Mangum

logger, tracer, metrics = Logger(), Tracer(), Metrics(namespace="DevOpsWikiSearch")
app = FastAPI()
_asgi = Mangum(app, lifespan="off")

@logger.inject_lambda_context(correlation_id_path="requestContext.requestId")
@tracer.capture_lambda_handler
@metrics.log_metrics(capture_cold_start_metric=True)
def handler(event, context):
    return _asgi(event, context)
```

## Decorator Order (outer → inner)

1. `@logger.inject_lambda_context` (correlation ID)
2. `@tracer.capture_lambda_handler` (X-Ray)
3. `@metrics.log_metrics` (flushes EMF last)

Mangum: `lifespan="off"` required; set `api_gateway_base_path` only if stage path in URL.

## Pydantic v2 Request/Response

```python
from pydantic import BaseModel, Field

class SearchRequest(BaseModel):
    q: str = Field(min_length=1, max_length=200)
    page: int = Field(default=1, ge=1, le=100)
    sources: list[str] | None = None

class SearchHit(BaseModel):
    source: str        # "ado" | "mediawiki" | "discourse"
    title: str
    url: str
    snippet: str
    score: float

class SearchResponse(BaseModel):
    query: str
    hits: list[SearchHit]
    partial: bool = False
    errors: dict[str, str] = {}
```

## Async Fan-Out

```python
async with httpx.AsyncClient(timeout=5.0) as c:
    results = await asyncio.gather(
        search_ado(c, q), search_mediawiki(c, q), search_discourse(c, q),
        return_exceptions=True,
    )
```

## Cold-Start Levers

| Lever | Effect |
|-------|--------|
| Lazy-import heavy libs (`boto3`, indexer) | -200 ms |
| SnapStart (Python 3.12, free) | ~10x faster init |
| Mangum `lifespan="off"` | -30 ms |
| Memory = 1024 MB | Faster init CPU |

## Logging + Metrics

```python
logger.info("search_executed", extra={"query": q, "hits": len(hits)})
metrics.add_metric(name="SearchHits", unit=MetricUnit.Count, value=len(hits))
metrics.add_dimension(name="Source", value="ado")
```

## Error JSON Shape

```json
{"error": "upstream_timeout", "detail": "mediawiki 5s exceeded", "correlation_id": "abc-123"}
```

## Common Pitfalls

| Don't | Do |
|-------|-----|
| Import `boto3` at module top | Lazy-import on first use |
| `requests` (sync) in async route | `httpx.AsyncClient` |
| Swallow exceptions silently | `partial=True` + record per-source error |
| Return raw `dict` from route | Return a Pydantic model |

## Related

- [Full index](index.md) · [Aggregator](patterns/aggregator-handler.md) · [Errors](patterns/error-handling.md)
