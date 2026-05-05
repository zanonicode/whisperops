# Mangum: ASGI Adapter for API Gateway

> **Purpose:** Translate API Gateway events into ASGI calls so FastAPI runs unchanged on Lambda.
> **Confidence:** HIGH
> **MCP Validated:** 2026-04-23

## What Mangum Does

AWS Lambda invocations deliver a JSON `event` shaped by API Gateway (v1 REST or v2 HTTP). FastAPI expects the ASGI protocol (`scope`, `receive`, `send`). Mangum is a thin adapter that:

1. Parses the API GW event into an ASGI `scope` dict (HTTP method, headers, path, query string, body).
2. Feeds the request body to the app via an ASGI `receive` coroutine.
3. Captures the app's ASGI `send` calls and serializes them back into the API GW response shape (status code, headers, body, `isBase64Encoded`).

## The Pattern

```python
from fastapi import FastAPI
from mangum import Mangum

app = FastAPI()

@app.get("/search")
async def search(q: str) -> dict:
    return {"query": q, "hits": []}

# Mangum wraps the ASGI app; handler is what Lambda calls
handler = Mangum(app, lifespan="off")
```

API Gateway calls `handler(event, context)`; Mangum does the rest.

## Event Format Support

| Format | Source | Mangum Handles |
|--------|--------|----------------|
| API GW REST (v1) | `/search?q=foo` via REST API | Yes |
| API GW HTTP (v2) | HTTP API (preferred, cheaper) | Yes |
| ALB | Application Load Balancer | Yes |
| Lambda Function URL | Direct URL | Yes (v2 format) |

Mangum auto-detects format — no config needed.

## Key Configuration

```python
Mangum(
    app,
    lifespan="off",           # REQUIRED on Lambda
    api_gateway_base_path="/prod",  # If API GW stage is in path
    text_mime_types=["application/json", "application/javascript", "text/*"],
    custom_handlers=None,
)
```

### Why `lifespan="off"`

ASGI "lifespan" events (`startup`, `shutdown`) don't map to Lambda — each invocation is isolated. Leaving lifespan on causes warnings and ~30 ms wasted per invocation waiting for a startup event that never triggers.

### Base-Path Stripping

If API GW stage path is `/prod/search`, FastAPI sees `/prod/search`. Use `api_gateway_base_path="/prod"` so FastAPI routes match `/search` cleanly. With HTTP API (v2) + custom domain, usually unneeded.

## Binary Responses

Mangum base64-encodes responses whose MIME type isn't in `text_mime_types`. For our JSON-only search API the default list suffices. Sets `isBase64Encoded=true` automatically when needed.

## Common Mistakes

### Wrong: Treating `handler` as the FastAPI app

```python
handler = Mangum(app)
# handler.include_router(...)  # ERROR — handler is a callable, not FastAPI
```

### Correct: Configure FastAPI first, wrap last

```python
app = FastAPI()
app.include_router(search_router)
handler = Mangum(app, lifespan="off")  # Wrap at module bottom
```

### Wrong: Re-creating Mangum per invocation

```python
def handler(event, context):
    return Mangum(app)(event, context)  # Re-init every call → slow
```

### Correct: Module-level instance

```python
_asgi = Mangum(app, lifespan="off")

def handler(event, context):
    return _asgi(event, context)
```

## Related

- [cold-start-mitigation](cold-start-mitigation.md) — why module-level init matters
- [../patterns/aggregator-handler.md](../patterns/aggregator-handler.md)
