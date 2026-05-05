# Pattern: Typed API Client

> **Purpose**: A small, typed fetch wrapper that mirrors backend Pydantic
> schemas and threads `AbortSignal`
> **MCP Validated**: 2026-04-23

## When to Use

Every call to the backend `/search` endpoint goes through this module. Keeping
it tiny (one file, ~40 lines) makes it trivial to mock in tests.

## Types (Mirror Backend Pydantic)

```ts
// src/types/search.ts
export type SourceId = 'ado' | 'mediawiki' | 'discourse';

export interface SearchHit {
  id: string;
  title: string;
  snippet: string;        // HTML with <mark> from FTS5 snippet()
  url: string;
  source: SourceId;
  score: number;          // bm25 score — lower = better
}

export interface SearchResponse {
  hits: SearchHit[];
  cursor: string | null;  // null when no more pages
  total: number;
}

export class ApiError extends Error {
  constructor(public status: number, message: string) {
    super(message);
    this.name = 'ApiError';
  }
}
```

**Rule:** any change to `backend/schemas/search.py` (Pydantic) must be
hand-mirrored here. Include a comment pointing at the backend file if useful.

## The Client

```ts
// src/api/search.ts
import type { SearchResponse } from '../types/search';
import { ApiError } from '../types/search';

const BASE = import.meta.env.VITE_API_BASE ?? '/api';

export async function searchApi(
  query: string,
  cursor: string | null = null,
  signal?: AbortSignal,
): Promise<SearchResponse> {
  const url = new URL(`${BASE}/search`, window.location.origin);
  url.searchParams.set('q', query);
  if (cursor) url.searchParams.set('cursor', cursor);

  const token = await getAccessToken();   // from microsoft-sso KB

  const res = await fetch(url, {
    signal,
    headers: {
      Accept: 'application/json',
      Authorization: `Bearer ${token}`,
    },
  });

  if (!res.ok) {
    const body = await res.text().catch(() => '');
    throw new ApiError(res.status, `Search failed (${res.status}): ${body}`);
  }

  return (await res.json()) as SearchResponse;
}
```

> `getAccessToken()` is provided by the MSAL integration — see sibling
> `microsoft-sso` KB. Treat it as an opaque dependency here.

## Thread the AbortSignal

```ts
useEffect(() => {
  const ctrl = new AbortController();
  searchApi(query, null, ctrl.signal)
    .then(setResponse)
    .catch((e) => { if (e.name !== 'AbortError') setError(e); });
  return () => ctrl.abort();
}, [query]);
```

`AbortError` propagates from `fetch` → swallow it; any other error is real.

## Environment Config

```
# .env.local
VITE_API_BASE=https://api.devops-wiki.o9solutions.com
```

Vite exposes `VITE_*` to client code via `import.meta.env`. Never put secrets
here — it's bundled into the JS.

## Error Surface

| HTTP | UI Behavior |
|------|-------------|
| 200 | Render results |
| 400 | "Invalid query" message (backend validation) |
| 401 | Redirect to MSAL login (handled by auth interceptor) |
| 429 | "Too many requests — try again in a moment" |
| 5xx | "Search is temporarily unavailable" |

Map `ApiError.status` in the page, not in the client — keeps the client
reusable.

## Testing with `fetch` Mock

```ts
// src/api/search.test.ts
import { describe, it, expect, vi } from 'vitest';
import { searchApi } from './search';

describe('searchApi', () => {
  it('appends cursor when provided', async () => {
    const fetchMock = vi.fn().mockResolvedValue(new Response(
      JSON.stringify({ hits: [], cursor: null, total: 0 }),
      { status: 200 }
    ));
    vi.stubGlobal('fetch', fetchMock);
    await searchApi('kubernetes', 'abc');
    const url = new URL(fetchMock.mock.calls[0][0]);
    expect(url.searchParams.get('q')).toBe('kubernetes');
    expect(url.searchParams.get('cursor')).toBe('abc');
  });

  it('throws ApiError on 500', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(new Response('boom', { status: 500 })));
    await expect(searchApi('k')).rejects.toThrow(/500/);
  });
});
```

## Why Not Axios / TanStack Query?

For a single endpoint with a single-page app, a 40-line fetch wrapper is
simpler, zero-dep, and tree-shake-friendly. If the API grows to 5+ endpoints
with caching/retry needs, migrate to TanStack Query then — not before.

## Common Mistakes

| Wrong | Right |
|-------|-------|
| Hardcoded full URL | `import.meta.env.VITE_API_BASE` |
| Forgetting `await res.text()` on error | Include body in `ApiError` for debugging |
| Not passing `signal` through | Superseded requests pile up |
| Letting types drift from backend | Mirror Pydantic on every schema change |

## Related

- [search-page-component.md](search-page-component.md) — consumer of this client
- [../concepts/debounced-search.md](../concepts/debounced-search.md) — AbortSignal usage
- `microsoft-sso/...` (sibling KB) — `getAccessToken()` implementation
- `fastapi-lambda/...` (sibling KB) — backend `/search` contract
