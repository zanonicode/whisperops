# Cold-Start Mitigation on Lambda

> **Purpose:** Keep P95 cold start under 1.5 s for a FastAPI + Mangum + Pydantic v2 + Powertools Lambda.
> **Confidence:** HIGH
> **MCP Validated:** 2026-04-23

## The Cold-Start Budget

A cold start on Python 3.12 Lambda with our stack typically breaks down as:

| Phase | Time (approx) | Notes |
|-------|---------------|-------|
| Init — runtime bootstrap | 150 ms | AWS-managed, not tunable |
| Init — module imports | 400–900 ms | **Biggest lever** |
| Init — Mangum wrap + routes | 50 ms | Minimal |
| First handler call | 50 ms | ASGI cycle |
| **Total cold** | 700–1200 ms | Warm is ~30 ms |

## Lever 1 — Lazy Imports

Defer heavy imports until the code path that needs them runs. Modules imported at the top of `app.py` run on every cold start.

### Wrong

```python
# app.py — top level
import boto3                # ~200 ms
import sqlite3              # ~20 ms
from mypkg.indexer import build_index  # drags in markdown-it-py
```

### Correct

```python
# app.py — top level: only route wiring
from fastapi import FastAPI
from mangum import Mangum

app = FastAPI()

@app.get("/search")
async def search(q: str):
    # Imports happen only when /search is invoked
    from mypkg.search import run_search
    return await run_search(q)
```

For clients reused across requests (like `httpx.AsyncClient`), initialize lazily on first use and cache at module scope:

```python
_client: httpx.AsyncClient | None = None

async def get_client() -> httpx.AsyncClient:
    global _client
    if _client is None:
        _client = httpx.AsyncClient(timeout=5.0)
    return _client
```

## Lever 2 — `/tmp` Reuse

Lambda's `/tmp` (512 MB default, up to 10 GB) persists across *warm* invocations. Use it to cache:

- SQLite FTS5 index (hydrated from S3 on cold start — see `sqlite-fts5/patterns/lambda-persistence.md`)
- MSAL JWKS keys (for token validation)
- Any computed lookup tables

Sentinel pattern:

```python
from pathlib import Path
SENTINEL = Path("/tmp/.index-ready")
if not SENTINEL.exists():
    hydrate_from_s3()
    SENTINEL.touch()
```

## Lever 3 — Memory Sizing

CPU scales with memory on Lambda. Going from 512 MB to 1024 MB roughly halves import time (CPU-bound). Use AWS Lambda Power Tuning to find the cost/latency sweet spot — typically **1024 MB** for FastAPI apps.

## Lever 4 — Provisioned Concurrency

For <100 concurrent users, cold starts are rare but jarring. Options:

| Option | Cost (1 unit, 1024 MB) | Effect |
|--------|------------------------|--------|
| None | $0 | Cold starts on every idle gap |
| Provisioned Concurrency = 1 | ~$6/mo | Near-zero cold starts during business hours |
| SnapStart (Python 3.12) | Free (tagged pricing) | ~10x faster init via restored snapshots |

**Recommendation for this project:** enable **SnapStart** — free, works on Python 3.12, no code changes required (just toggle in Lambda console / IaC). Skip provisioned concurrency given the <$50/mo budget.

## Lever 5 — Mangum `lifespan="off"`

Saves ~30 ms per cold start by skipping ASGI startup event coordination. See [mangum-adapter.md](mangum-adapter.md).

## Lever 6 — Keep the Package Small

Lambda unzipped package is capped at 250 MB. Use Lambda Layers for big deps; `uv export --no-dev` to strip dev tooling. See `aws-serverless-web` KB.

## Measuring

Powertools auto-emits a `ColdStart` metric when `capture_cold_start_metric=True`:

```python
@metrics.log_metrics(capture_cold_start_metric=True)
def handler(event, context): ...
```

Check CloudWatch → Metrics → `DevOpsWikiSearch/ColdStart`. Alarm if P95 > 2000 ms.

## Related

- [mangum-adapter](mangum-adapter.md)
- [powertools-integration](powertools-integration.md)
- [../../sqlite-fts5/patterns/lambda-persistence.md](../../sqlite-fts5/patterns/lambda-persistence.md)
