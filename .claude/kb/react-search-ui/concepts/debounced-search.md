# Debounced Search-as-You-Type

> **Purpose**: Fetch results while the user types, without hammering the backend
> **Confidence**: HIGH
> **MCP Validated**: 2026-04-23

## Why Debounce

A user typing "kubernetes rollback" fires ~18 keystrokes. Without debounce,
each keystroke kicks off a `/search` call — wasteful, and late responses can
overwrite fresh ones (race condition). Two mechanics solve this together:

1. **Debounce** — wait until the user pauses (~300ms) before firing.
2. **AbortController** — cancel the prior in-flight request when a new one
   starts, so a slow response for `"kuber"` cannot overwrite the result for
   `"kubernetes"`.

## `useDebounce` Hook

```ts
import { useEffect, useState } from 'react';

export function useDebounce<T>(value: T, delayMs: number): T {
  const [debounced, setDebounced] = useState(value);
  useEffect(() => {
    const id = setTimeout(() => setDebounced(value), delayMs);
    return () => clearTimeout(id);    // cancels if value changes again
  }, [value, delayMs]);
  return debounced;
}
```

Usage:

```ts
const [query, setQuery] = useState('');
const debouncedQuery = useDebounce(query, 300);
// useEffect below only fires when the user pauses typing
```

## AbortController for Superseded Fetches

```ts
import { useEffect, useState } from 'react';

export function useSearch(query: string) {
  const [hits, setHits] = useState<SearchHit[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<Error | null>(null);

  useEffect(() => {
    if (!query) { setHits([]); return; }
    const ctrl = new AbortController();
    setLoading(true);

    fetch(`/api/search?q=${encodeURIComponent(query)}`, { signal: ctrl.signal })
      .then((r) => r.json())
      .then((data: SearchResponse) => setHits(data.hits))
      .catch((e) => { if (e.name !== 'AbortError') setError(e); })
      .finally(() => setLoading(false));

    return () => ctrl.abort();        // fires on next query or unmount
  }, [query]);

  return { hits, loading, error };
}
```

## Debounce Value: 300ms

| Delay | Feel | Wasted Requests |
|-------|------|-----------------|
| 100ms | Fires mid-word | High |
| **300ms** | **Sweet spot** | **Low** |
| 500ms | Feels laggy | Very low |

300ms is standard across search UIs (Algolia default, GitHub search).

## Common Mistakes

### Wrong — race condition

```ts
// Without AbortController, a slow response for "kuber" may arrive AFTER
// the response for "kubernetes" and overwrite the correct results.
useEffect(() => {
  fetch(`/api/search?q=${query}`).then(r => r.json()).then(setHits);
}, [query]);
```

### Wrong — debouncing the callback, not the value

```ts
// Re-creates the debounced fn every render → breaks.
const onChange = debounce((v) => setQuery(v), 300);
```

### Correct — debounce the value, abort the fetch

```ts
const debouncedQuery = useDebounce(query, 300);
useEffect(() => {
  const ctrl = new AbortController();
  fetch(url, { signal: ctrl.signal })...;
  return () => ctrl.abort();
}, [debouncedQuery]);
```

## Edge Cases

| Case | Handling |
|------|----------|
| User clears input | Reset `hits: []`, skip fetch |
| User types < 2 chars | Skip fetch (backend minimum) |
| AbortError thrown | Ignore silently — it's expected |
| Component unmounts mid-fetch | `return () => ctrl.abort()` covers it |

## Related

- [patterns/search-page-component.md](../patterns/search-page-component.md) — wiring it all together
- [patterns/api-client-typed.md](../patterns/api-client-typed.md) — typed fetch wrapper
