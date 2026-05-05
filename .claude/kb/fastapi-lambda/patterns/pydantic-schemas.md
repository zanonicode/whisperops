# Pattern: Pydantic v2 Schemas for /search

> **Purpose:** Strongly-typed request and response models — drives validation, OpenAPI docs, and the TS type mirror on the frontend.
> **MCP Validated:** 2026-04-23

## When to Use

- Every HTTP route on the aggregator Lambda.
- Any internal boundary where data crosses async tasks (source-search results → aggregator).

## The Schemas

```python
# app/schemas.py
from __future__ import annotations

from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, HttpUrl

SourceName = Literal["ado", "mediawiki", "discourse"]


class SearchRequest(BaseModel):
    """Query params for GET /search. Used via FastAPI `Query(...)` — shown here for reference."""

    model_config = ConfigDict(extra="forbid")

    q: str = Field(min_length=1, max_length=200, description="Search keyword")
    page: int = Field(default=1, ge=1, le=100)
    sources: list[SourceName] | None = Field(
        default=None,
        description="Restrict to subset of sources; None = all three",
    )


class SearchHit(BaseModel):
    """Single search result, normalized across sources."""

    model_config = ConfigDict(extra="forbid")

    source: SourceName
    title: str = Field(min_length=1, max_length=500)
    url: HttpUrl
    snippet: str = Field(max_length=1000, description="Highlighted text fragment (HTML allowed)")
    score: float = Field(ge=0.0, le=1.0, description="Normalized relevance score")


class SearchResponse(BaseModel):
    """Aggregated response from all queried sources."""

    model_config = ConfigDict(extra="forbid")

    query: str
    hits: list[SearchHit]
    partial: bool = Field(
        default=False,
        description="True if one or more sources failed — check `errors`",
    )
    errors: dict[SourceName, str] = Field(
        default_factory=dict,
        description="Map of source name → exception type for failed sources",
    )


class ErrorResponse(BaseModel):
    """Standardized error shape for HTTP >=400."""

    model_config = ConfigDict(extra="forbid")

    error: str = Field(description="Short machine code: 'bad_request', 'unauthorized', ...")
    detail: str = Field(description="Human-readable explanation")
    correlation_id: str | None = None
```

## Using Schemas in Routes

```python
from fastapi import APIRouter, Query
from app.schemas import SearchResponse

router = APIRouter()

@router.get("/search", response_model=SearchResponse)
async def search(
    q: str = Query(min_length=1, max_length=200),
    page: int = Query(default=1, ge=1, le=100),
) -> SearchResponse:
    ...
    return SearchResponse(query=q, hits=hits, partial=False)
```

FastAPI enforces the `response_model` on the way out — extra fields are stripped, missing fields raise 500. This is intentional: the OpenAPI contract is the single source of truth.

## Why `model_config = ConfigDict(extra="forbid")`

- Catches typos in internal callers (e.g. `SearchHit(titel="...")` fails fast).
- Prevents silent field drift between backend and hand-mirrored TS types.

## Why `HttpUrl`

- Validates `url` is a real URL at construct time, not at display time on the frontend.
- Serializes as plain string in JSON — no frontend impact.

## Mirrored TypeScript Types

Maintain a hand-written mirror in the frontend — don't auto-generate from OpenAPI in v1 (adds build complexity for <100 users):

```typescript
// src/types/search.ts
export type SourceName = "ado" | "mediawiki" | "discourse";

export interface SearchHit {
  source: SourceName;
  title: string;
  url: string;
  snippet: string;
  score: number;
}

export interface SearchResponse {
  query: string;
  hits: SearchHit[];
  partial: boolean;
  errors: Partial<Record<SourceName, string>>;
}
```

Any change to `app/schemas.py` demands a matching change here — enforced via code review.

## Validation Example

```python
>>> SearchRequest(q="", page=1)
ValidationError: q: String should have at least 1 character

>>> SearchRequest(q="k8s", page=0)
ValidationError: page: Input should be greater than or equal to 1

>>> SearchRequest(q="k8s", sources=["gitlab"])
ValidationError: sources: Input should be 'ado', 'mediawiki' or 'discourse'
```

FastAPI converts these into HTTP 422 responses with the field path — frontend shows them inline.

## Evolving the Schema

- **Adding a field:** give it a default, deploy backend first, then frontend.
- **Removing a field:** deploy frontend first (stop reading), then backend.
- **Renaming:** add new + keep old with `Field(alias=...)` for one release cycle.

## Related

- [aggregator-handler](aggregator-handler.md) — how schemas plug into routes
- [error-handling](error-handling.md) — `ErrorResponse` usage
- `.claude/kb/pydantic/` — Pydantic v2 fundamentals (partial reuse)
