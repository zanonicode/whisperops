# AWS Lambda Powertools Integration

> **Purpose:** Structured JSON logs, X-Ray tracing, and EMF metrics with minimal boilerplate.
> **Confidence:** HIGH
> **MCP Validated:** 2026-04-23

## The Three Pillars

| Component | Decorator | What It Does |
|-----------|-----------|--------------|
| `Logger` | `@logger.inject_lambda_context` | Structured JSON logs with Lambda context + correlation ID |
| `Tracer` | `@tracer.capture_lambda_handler` | X-Ray segments + subsegments + method tracing |
| `Metrics` | `@metrics.log_metrics` | Embedded Metric Format (EMF) — custom metrics via stdout |

## Module-Level Setup

```python
# app.py
from aws_lambda_powertools import Logger, Metrics, Tracer

logger = Logger(service="devops-wiki-search")
tracer = Tracer(service="devops-wiki-search")
metrics = Metrics(namespace="DevOpsWikiSearch", service="devops-wiki-search")
```

Service name flows into logs, trace subsegments, and metric dimensions — set it once.

## Handler Decoration (Order Matters)

```python
@logger.inject_lambda_context(
    correlation_id_path="requestContext.requestId",
    log_event=False,  # Don't log the full event (may contain tokens)
)
@tracer.capture_lambda_handler
@metrics.log_metrics(capture_cold_start_metric=True, raise_on_empty_metrics=False)
def handler(event, context):
    return _asgi(event, context)
```

**Outer-to-inner:** logger injects context first (so tracer/metrics inherit correlation ID), tracer opens the segment, metrics flushes last.

## Correlation IDs

`correlation_id_path="requestContext.requestId"` extracts the API Gateway request ID and attaches it to every log line in this invocation. FastAPI routes pick it up automatically via `logger`:

```python
from aws_lambda_powertools import Logger

logger = Logger(child=True)  # Inherits service + correlation ID from root

@app.get("/search")
async def search(q: str):
    logger.info("search_received", extra={"query": q})
    # → {"correlation_id":"a1b2-c3d4", "query":"k8s", ...}
```

## Tracing Custom Functions

```python
@tracer.capture_method
async def search_mediawiki(client: httpx.AsyncClient, q: str) -> list[SearchHit]:
    tracer.put_annotation("source", "mediawiki")
    tracer.put_metadata("query", q)
    resp = await client.get(...)
    return parse(resp.json())
```

Annotations are indexed by X-Ray (filterable); metadata is attached but not indexed.

## Metrics Patterns

```python
from aws_lambda_powertools.metrics import MetricUnit

# Counter
metrics.add_metric(name="SearchRequests", unit=MetricUnit.Count, value=1)

# Per-source latency
metrics.add_metric(name="SourceLatency", unit=MetricUnit.Milliseconds, value=elapsed_ms)
metrics.add_dimension(name="Source", value="mediawiki")

# Partial-success rate
metrics.add_metric(name="PartialResponses", unit=MetricUnit.Count, value=1 if partial else 0)
```

EMF is emitted as structured JSON to stdout; CloudWatch auto-ingests.

## Cold-Start Metric

`capture_cold_start_metric=True` on `@metrics.log_metrics` emits a `ColdStart` count metric exactly once per cold invocation — zero code to write.

## Log Shape (Default)

```json
{
  "level": "INFO",
  "location": "search:42",
  "message": "search_executed",
  "timestamp": "2026-04-23T22:38:17.123Z",
  "service": "devops-wiki-search",
  "cold_start": false,
  "function_name": "devops-wiki-search-api",
  "function_memory_size": "1024",
  "function_arn": "arn:aws:lambda:...",
  "function_request_id": "a1b2-c3d4",
  "correlation_id": "a1b2-c3d4",
  "query": "k8s",
  "hits": 17
}
```

Pipe into CloudWatch Logs Insights directly:

```sql
fields @timestamp, correlation_id, query, hits
| filter message = "search_executed"
| stats avg(hits) by bin(1h)
```

## Common Mistakes

| Don't | Do |
|-------|-----|
| `print(...)` for logs | `logger.info(...)` — gets correlation ID + JSON shape |
| `log_event=True` in production | Leave `False` — event may contain auth tokens |
| Instantiate `Logger()` per request | Module-level singleton; use `Logger(child=True)` in submodules |
| Forget `capture_cold_start_metric` | Always enable — free signal |

## Related

- [cold-start-mitigation](cold-start-mitigation.md)
- [../patterns/error-handling.md](../patterns/error-handling.md)
