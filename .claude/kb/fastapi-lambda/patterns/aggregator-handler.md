# Pattern: /search Aggregator Handler

> **Purpose:** Single endpoint that fans out to 3 sources in parallel, merges hits, returns a unified response.
> **MCP Validated:** 2026-04-23

## When to Use

- You need to query N heterogeneous sources concurrently inside a single Lambda.
- Each source has its own latency profile and failure mode.
- You want partial-success (one slow/broken source shouldn't blank the whole response).

## Architecture

```text
GET /search?q=<kw>&page=<n>
    │
    ▼
┌──────────────────────────────────┐
│ FastAPI route → asyncio.gather() │
└─────┬────────────┬───────────┬───┘
      │            │           │
   ADO (FTS5)   MediaWiki   Discourse
   (~20 ms)    (~300 ms)   (~400 ms)
      │            │           │
      └────────────┴───────────┘
              │ merge + rank
              ▼
      SearchResponse (JSON)
```

## Full Implementation

```python
# app/routes/search.py
from __future__ import annotations

import asyncio
import time

import httpx
from aws_lambda_powertools import Logger, Metrics, Tracer
from aws_lambda_powertools.metrics import MetricUnit
from fastapi import APIRouter, Depends, HTTPException, Query

from app.schemas import SearchHit, SearchResponse
from app.sources import discourse, mediawiki
from app.sources import ado_fts5 as ado

router = APIRouter()
logger = Logger(child=True)
tracer = Tracer()
metrics = Metrics()

# Module-level client — reused across warm invocations
_client: httpx.AsyncClient | None = None


async def get_client() -> httpx.AsyncClient:
    global _client
    if _client is None:
        _client = httpx.AsyncClient(
            timeout=httpx.Timeout(connect=2.0, read=5.0, write=2.0, pool=2.0),
            limits=httpx.Limits(max_connections=20),
        )
    return _client


@router.get("/search", response_model=SearchResponse)
@tracer.capture_method
async def search(
    q: str = Query(min_length=1, max_length=200),
    page: int = Query(default=1, ge=1, le=100),
    sources: list[str] | None = Query(default=None),
    client: httpx.AsyncClient = Depends(get_client),
) -> SearchResponse:
    active = sources or ["ado", "mediawiki", "discourse"]
    logger.info("search_received", extra={"query": q, "page": page, "sources": active})

    tasks = []
    if "ado" in active:
        tasks.append(_timed("ado", ado.search(q, page)))
    if "mediawiki" in active:
        tasks.append(_timed("mediawiki", mediawiki.search(client, q, page)))
    if "discourse" in active:
        tasks.append(_timed("discourse", discourse.search(client, q, page)))

    results = await asyncio.gather(*tasks, return_exceptions=True)

    hits: list[SearchHit] = []
    errors: dict[str, str] = {}
    for source, outcome in zip(active, results, strict=True):
        if isinstance(outcome, Exception):
            errors[source] = type(outcome).__name__
            logger.warning("source_failed", extra={"source": source, "error": str(outcome)})
            continue
        hits.extend(outcome)

    hits.sort(key=lambda h: h.score, reverse=True)

    metrics.add_metric(name="SearchHits", unit=MetricUnit.Count, value=len(hits))
    if errors:
        metrics.add_metric(name="PartialResponses", unit=MetricUnit.Count, value=1)

    return SearchResponse(
        query=q,
        hits=hits,
        partial=bool(errors),
        errors=errors,
    )


async def _timed(source: str, coro) -> list[SearchHit]:
    """Run a source search and emit per-source latency."""
    t0 = time.monotonic()
    try:
        return await coro
    finally:
        elapsed_ms = (time.monotonic() - t0) * 1000
        metrics.add_metric(
            name="SourceLatency",
            unit=MetricUnit.Milliseconds,
            value=elapsed_ms,
        )
        metrics.add_dimension(name="Source", value=source)
```

## Source-Function Contract

Each source module exposes an `async def search(...) -> list[SearchHit]` that:

1. Applies its own per-call timeout (via `httpx` timeout or local `asyncio.wait_for`).
2. Returns normalized `SearchHit` objects — score comparable across sources (simple 0–1 rank).
3. Raises on failure — the aggregator catches via `return_exceptions=True`.

Example stub:

```python
# app/sources/mediawiki.py
import httpx
from app.schemas import SearchHit

BASE = "https://platformwiki.o9solutions.com/api.php"

async def search(client: httpx.AsyncClient, q: str, page: int) -> list[SearchHit]:
    resp = await client.get(BASE, params={
        "action": "query", "list": "search", "srsearch": q,
        "format": "json", "sroffset": (page - 1) * 20, "srlimit": 20,
    })
    resp.raise_for_status()
    data = resp.json()
    return [
        SearchHit(
            source="mediawiki",
            title=r["title"],
            url=f"https://platformwiki.o9solutions.com/wiki/{r['title'].replace(' ', '_')}",
            snippet=r.get("snippet", ""),
            score=1.0 / (i + 1),  # rank-based
        )
        for i, r in enumerate(data["query"]["search"])
    ]
```

## Why `asyncio.gather(return_exceptions=True)`

- Without it, one source's exception cancels the others.
- With it, all three always complete — we reconcile results after.
- Pair with per-call timeouts so a hanging source can't stall the whole handler past the Lambda timeout.

## Merge Strategy (v1)

Simple descending-by-score with source-weighted normalization. If relevance ranking becomes a concern (R4), revisit — but don't over-engineer for <100 users.

## Related

- [pydantic-schemas](pydantic-schemas.md) — `SearchHit` / `SearchResponse`
- [error-handling](error-handling.md) — timeout + partial responses
- `python-httpx-async` KB (upcoming) — retry, circuit-breaker
