# Pattern: SearchPage Component

> **Purpose**: The single page of the app — search box + infinite-scroll results
> **MCP Validated**: 2026-04-23

## When to Use

This is **the** top-level component of the SPA. Mount it under your MSAL
provider (see `microsoft-sso` KB) and inside `<BrowserRouter>` if routing is
added later.

## Implementation

```tsx
// src/pages/SearchPage.tsx
import { useCallback, useEffect, useRef, useState } from 'react';
import { useDebounce } from '../hooks/useDebounce';
import { useDarkMode } from '../hooks/useDarkMode';
import { searchApi } from '../api/search';
import { ResultItem } from '../components/ResultItem';
import type { SearchHit } from '../types/search';

export function SearchPage() {
  const [query, setQuery] = useState('');
  const debounced = useDebounce(query.trim(), 300);

  const [hits, setHits] = useState<SearchHit[]>([]);
  const [cursor, setCursor] = useState<string | null>(null);
  const [hasMore, setHasMore] = useState(false);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const sentinelRef = useRef<HTMLDivElement>(null);
  const [isDark, setIsDark] = useDarkMode();

  // Reset on new query; fetch first page
  useEffect(() => {
    if (debounced.length < 2) { setHits([]); setHasMore(false); return; }
    const ctrl = new AbortController();
    setLoading(true); setError(null); setHits([]); setCursor(null);

    searchApi(debounced, null, ctrl.signal)
      .then((r) => { setHits(r.hits); setCursor(r.cursor); setHasMore(r.cursor !== null); })
      .catch((e) => { if (e.name !== 'AbortError') setError(e.message); })
      .finally(() => setLoading(false));

    return () => ctrl.abort();
  }, [debounced]);

  // Load next page
  const loadMore = useCallback(async () => {
    if (!hasMore || loading || !cursor) return;
    setLoading(true);
    try {
      const r = await searchApi(debounced, cursor);
      setHits((prev) => [...prev, ...r.hits]);
      setCursor(r.cursor);
      setHasMore(r.cursor !== null);
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setLoading(false);
    }
  }, [debounced, cursor, hasMore, loading]);

  // Observe the sentinel
  useEffect(() => {
    if (!sentinelRef.current || !hasMore) return;
    const obs = new IntersectionObserver(
      (entries) => { if (entries[0].isIntersecting) loadMore(); },
      { rootMargin: '200px' }
    );
    obs.observe(sentinelRef.current);
    return () => obs.disconnect();
  }, [hasMore, loadMore]);

  return (
    <div className="min-h-screen bg-white text-slate-900 dark:bg-slate-900 dark:text-slate-100">
      <header className="sticky top-0 z-10 border-b border-slate-200 bg-white/80 backdrop-blur dark:border-slate-700 dark:bg-slate-900/80">
        <div className="mx-auto flex max-w-3xl items-center gap-3 px-4 py-3">
          <input
            type="search"
            autoFocus
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            placeholder="Search DevOps Wiki, Platform Wiki, Community…"
            className="flex-1 rounded-lg border border-slate-300 bg-white px-4 py-2 text-base outline-none focus:border-blue-500 dark:border-slate-600 dark:bg-slate-800"
          />
          <button
            onClick={() => setIsDark(!isDark)}
            aria-label="Toggle dark mode"
            className="rounded p-2 hover:bg-slate-200 dark:hover:bg-slate-700"
          >
            {isDark ? '☀' : '🌙'}
          </button>
        </div>
      </header>

      <main className="mx-auto max-w-3xl px-4 py-6">
        {error && (
          <div className="rounded border border-red-300 bg-red-50 p-4 text-red-800 dark:border-red-700 dark:bg-red-900/30 dark:text-red-200">
            {error}
          </div>
        )}

        {!error && debounced.length < 2 && (
          <p className="text-slate-500 dark:text-slate-400">
            Type at least 2 characters to search.
          </p>
        )}

        {!error && debounced.length >= 2 && !loading && hits.length === 0 && (
          <p className="text-slate-500 dark:text-slate-400">
            No results for &ldquo;{debounced}&rdquo;.
          </p>
        )}

        <ul className="space-y-3">
          {hits.map((h) => <ResultItem key={h.id} hit={h} />)}
        </ul>

        {loading && (
          <p className="py-4 text-center text-slate-500 dark:text-slate-400">Loading…</p>
        )}

        {hasMore && <div ref={sentinelRef} aria-hidden className="h-1" />}
      </main>
    </div>
  );
}
```

## UI States Covered

| State | Condition | Output |
|-------|-----------|--------|
| Idle | `debounced.length < 2` | Prompt to type more |
| Loading (first page) | `loading && hits.length === 0` | "Loading…" below empty list |
| Loading (next page) | `loading && hits.length > 0` | "Loading…" below existing list |
| Empty | `!loading && hits.length === 0` | "No results" message |
| Error | `error !== null` | Red alert banner |
| Results | `hits.length > 0` | Result list + sentinel |

## Related

- [result-item-with-snippet.md](result-item-with-snippet.md) — the `<ResultItem>` used above
- [api-client-typed.md](api-client-typed.md) — the `searchApi()` used above
- [../concepts/debounced-search.md](../concepts/debounced-search.md) — `useDebounce`
