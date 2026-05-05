# Pattern: Error Handling, Timeouts, and Partial Success

> **Purpose:** Keep the aggregator responsive even when upstream sources misbehave; return a predictable error JSON shape.
> **MCP Validated:** 2026-04-23

## When to Use

- Any route that fans out to external systems.
- Anywhere you'd be tempted to `except Exception: pass`.

## The Three Failure Modes

| Mode | Example | Handler Response |
|------|---------|------------------|
| Client error | Bad query param | HTTP 422 via FastAPI validation |
| One source fails | MediaWiki 5xx / timeout | HTTP 200 with `partial=true`, hit list from the other two |
| All sources fail | Network outage | HTTP 503 with standardized error body |

## Timeouts — Defense in Depth

Three layers, each tighter than the one above:

```python
# Layer 1: httpx transport timeout
client = httpx.AsyncClient(
    timeout=httpx.Timeout(connect=2.0, read=5.0, write=2.0, pool=2.0)
)

# Layer 2: asyncio timeout around the whole source search
async def search_mediawiki(client, q):
    async with asyncio.timeout(6.0):  # Python 3.11+
        return await _do_search(client, q)

# Layer 3: Lambda handler timeout (API GW max 29 s; set Lambda to 10 s)
```

## Global Exception Handlers

Standardize the HTTP response for any uncaught error on the FastAPI side:

```python
# app/errors.py
from aws_lambda_powertools import Logger
from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from starlette.exceptions import HTTPException

from app.schemas import ErrorResponse

logger = Logger(child=True)


def install_error_handlers(app: FastAPI) -> None:
    @app.exception_handler(RequestValidationError)
    async def validation_exc(request: Request, exc: RequestValidationError):
        return JSONResponse(
            status_code=422,
            content=ErrorResponse(
                error="bad_request",
                detail=str(exc.errors()[0]["msg"]) if exc.errors() else "invalid request",
                correlation_id=logger.get_correlation_id(),
            ).model_dump(),
        )

    @app.exception_handler(HTTPException)
    async def http_exc(request: Request, exc: HTTPException):
        return JSONResponse(
            status_code=exc.status_code,
            content=ErrorResponse(
                error=_code_for_status(exc.status_code),
                detail=exc.detail or "",
                correlation_id=logger.get_correlation_id(),
            ).model_dump(),
        )

    @app.exception_handler(Exception)
    async def unhandled(request: Request, exc: Exception):
        logger.exception("unhandled_error")
        return JSONResponse(
            status_code=500,
            content=ErrorResponse(
                error="internal_error",
                detail="unexpected server error",
                correlation_id=logger.get_correlation_id(),
            ).model_dump(),
        )


def _code_for_status(status: int) -> str:
    return {
        400: "bad_request",
        401: "unauthorized",
        403: "forbidden",
        404: "not_found",
        429: "rate_limited",
        503: "service_unavailable",
    }.get(status, "error")
```

Wire it up once:

```python
# app.py
from app.errors import install_error_handlers
app = FastAPI()
install_error_handlers(app)
```

## Partial Success (200 with `partial=true`)

The aggregator catches per-source failures and reports them without failing the whole request:

```python
results = await asyncio.gather(*tasks, return_exceptions=True)

hits: list[SearchHit] = []
errors: dict[str, str] = {}
for source, outcome in zip(active, results, strict=True):
    if isinstance(outcome, Exception):
        errors[source] = type(outcome).__name__
        logger.warning(
            "source_failed",
            extra={"source": source, "error_type": type(outcome).__name__, "error": str(outcome)},
        )
        continue
    hits.extend(outcome)

if not hits and errors:
    # All sources failed — escalate to 503
    raise HTTPException(status_code=503, detail="all upstream sources unavailable")

return SearchResponse(query=q, hits=hits, partial=bool(errors), errors=errors)
```

## Standardized Error JSON Shape

Every non-200 response from this Lambda looks like:

```json
{
  "error": "upstream_timeout",
  "detail": "mediawiki did not respond within 5s",
  "correlation_id": "a1b2-c3d4-e5f6"
}
```

Frontend can dispatch on `error` (short code) and display `detail` to the user. `correlation_id` lets support trace the exact request in CloudWatch.

## Per-Source Error Categories (Log Signals)

| Exception | Meaning | Metric |
|-----------|---------|--------|
| `httpx.ConnectTimeout` | Source unreachable | `SourceTimeouts` (with `Source` dim) |
| `httpx.ReadTimeout` | Source slow | same |
| `httpx.HTTPStatusError` (5xx) | Source broken | `SourceServerErrors` |
| `httpx.HTTPStatusError` (4xx) | Our bug — bad request to source | `SourceClientErrors` (alert on > 0) |
| Anything else | Unknown — investigate | `SourceUnknownErrors` (alert on > 0) |

Emit as Powertools metrics so CloudWatch alarms can fire:

```python
from aws_lambda_powertools.metrics import MetricUnit

def record_source_error(source: str, exc: Exception) -> None:
    if isinstance(exc, (httpx.ConnectTimeout, httpx.ReadTimeout)):
        name = "SourceTimeouts"
    elif isinstance(exc, httpx.HTTPStatusError):
        name = "SourceServerErrors" if exc.response.status_code >= 500 else "SourceClientErrors"
    else:
        name = "SourceUnknownErrors"
    metrics.add_metric(name=name, unit=MetricUnit.Count, value=1)
    metrics.add_dimension(name="Source", value=source)
```

## What Not to Do

| Don't | Why |
|-------|-----|
| `except Exception: return []` silently | Hides real bugs; no signal to alarm on |
| Leak exception strings as `detail` | May contain secrets or internal paths |
| Return 500 for one bad source | Users want the two working sources' hits |
| Use the same timeout everywhere | Tune per source; ADO-local FTS is ~20 ms, MediaWiki is ~300 ms |
| Retry on every 5xx inline | Adds latency; let a circuit breaker handle it (see `python-httpx-async` KB) |

## Related

- [aggregator-handler](aggregator-handler.md)
- [pydantic-schemas](pydantic-schemas.md) — `ErrorResponse`
- [../concepts/powertools-integration.md](../concepts/powertools-integration.md)
- `python-httpx-async` KB (upcoming) — retry + circuit breaker
