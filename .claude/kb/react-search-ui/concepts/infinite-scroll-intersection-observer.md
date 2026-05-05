# Infinite Scroll via IntersectionObserver

> **Purpose**: Load the next page of results when the user scrolls near the end
> **Confidence**: HIGH
> **MCP Validated**: 2026-04-23

## Why Not Scroll Listeners

The classic approach — listening to `window.onscroll` and computing
`scrollTop + clientHeight >= scrollHeight - threshold` — has three problems:

1. Fires on **every pixel**, forcing manual throttling.
2. Couples to layout; breaks inside nested scroll containers.
3. Reads geometry on every event → layout thrash.

`IntersectionObserver` is the native API designed for this: the browser
notifies you when a DOM element enters/leaves the viewport, off the main
thread, no throttling required.

## The Sentinel Pattern

Place an empty `<div>` at the end of the result list. When it scrolls into
view, fetch the next page:

```tsx
import { useEffect, useRef } from 'react';

function ResultList({ hits, hasMore, loadMore }: Props) {
  const sentinelRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (!sentinelRef.current || !hasMore) return;
    const obs = new IntersectionObserver(
      (entries) => { if (entries[0].isIntersecting) loadMore(); },
      { rootMargin: '200px' }     // fire 200px BEFORE sentinel is visible
    );
    obs.observe(sentinelRef.current);
    return () => obs.disconnect();
  }, [hasMore, loadMore]);

  return (
    <ul>
      {hits.map((h) => <ResultItem key={h.id} hit={h} />)}
      {hasMore && <div ref={sentinelRef} aria-hidden />}
    </ul>
  );
}
```

## Cursor vs Offset Pagination

Backend returns `cursor: string | null`. Frontend sends it back on next fetch:

```ts
GET /api/search?q=kubernetes              → { hits: [...], cursor: "eyJvIjoyMH0" }
GET /api/search?q=kubernetes&cursor=eyJ… → { hits: [...], cursor: null }  // end
```

| Approach | Pros | Cons |
|----------|------|------|
| **Cursor (opaque)** | Stable across inserts; backend-agnostic | Harder to "jump to page 5" |
| Offset (`&offset=40`) | Trivial | Skips/dupes when content mutates mid-scroll |

For a federated search across heterogeneous sources, **cursor wins** — each
source can encode its own pagination state inside the opaque token.

## `useInfiniteSearch` — Pulling It Together

```ts
export function useInfiniteSearch(query: string) {
  const [hits, setHits] = useState<SearchHit[]>([]);
  const [cursor, setCursor] = useState<string | null>(null);
  const [hasMore, setHasMore] = useState(false);

  // Reset when query changes
  useEffect(() => { setHits([]); setCursor(null); setHasMore(true); }, [query]);

  const loadMore = useCallback(async () => {
    const url = new URL('/api/search', location.origin);
    url.searchParams.set('q', query);
    if (cursor) url.searchParams.set('cursor', cursor);
    const r = await fetch(url).then((x) => x.json()) as SearchResponse;
    setHits((prev) => [...prev, ...r.hits]);
    setCursor(r.cursor);
    setHasMore(r.cursor !== null);
  }, [query, cursor]);

  return { hits, hasMore, loadMore };
}
```

## `rootMargin` Tuning

| Value | Effect |
|-------|--------|
| `0px` | Fires exactly when sentinel is visible — user sees spinner |
| **`200px`** | **Default — fetches just before user reaches bottom** |
| `600px` | Aggressive prefetch; may waste bandwidth |

## Common Mistakes

### Wrong — observing inside render

```tsx
// New observer every render → leaks + multi-fires
return <div ref={(el) => el && new IntersectionObserver(...).observe(el)} />;
```

### Wrong — forgetting disconnect

```ts
useEffect(() => {
  const obs = new IntersectionObserver(...);
  obs.observe(el);
  // missing return () => obs.disconnect()  → leak
});
```

### Wrong — infinite fetch loop

If `loadMore` doesn't update `cursor`/`hasMore`, the sentinel stays visible
and fires forever. Always gate on `hasMore` and update cursor after fetch.

## Related

- [patterns/search-page-component.md](../patterns/search-page-component.md) — full integration
- [concepts/debounced-search.md](debounced-search.md) — resetting on query change
