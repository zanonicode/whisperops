# Pattern: ResultItem with Safe HTML Snippet

> **Purpose**: Render a single search hit with source badge + backend-supplied
> highlighted snippet HTML
> **MCP Validated**: 2026-04-23

## When to Use

Each row in the infinite-scroll list. The snippet HTML comes from the backend
`snippet()` FTS5 function (see sibling `sqlite-fts5` KB) and contains
`<mark>` tags that must render — but nothing else.

## Implementation

```tsx
// src/components/ResultItem.tsx
import DOMPurify from 'dompurify';
import type { SearchHit, SourceId } from '../types/search';

const BADGE: Record<SourceId, { label: string; cls: string }> = {
  ado: {
    label: 'ADO Wiki',
    cls: 'bg-blue-100 text-blue-800 dark:bg-blue-900/40 dark:text-blue-200',
  },
  mediawiki: {
    label: 'Platform Wiki',
    cls: 'bg-green-100 text-green-800 dark:bg-green-900/40 dark:text-green-200',
  },
  discourse: {
    label: 'Community',
    cls: 'bg-purple-100 text-purple-800 dark:bg-purple-900/40 dark:text-purple-200',
  },
};

// Only allow <mark> with no attributes — backend highlights, nothing else.
const SANITIZE_OPTS: DOMPurify.Config = {
  ALLOWED_TAGS: ['mark'],
  ALLOWED_ATTR: [],
};

interface Props { hit: SearchHit; }

export function ResultItem({ hit }: Props) {
  const badge = BADGE[hit.source];
  const safeSnippet = DOMPurify.sanitize(hit.snippet, SANITIZE_OPTS);

  return (
    <li className="rounded-lg border border-slate-200 bg-white p-4 transition hover:border-blue-400 hover:shadow-sm dark:border-slate-700 dark:bg-slate-800 dark:hover:border-blue-500">
      <a
        href={hit.url}
        target="_blank"
        rel="noopener noreferrer"
        className="block focus:outline-none focus:ring-2 focus:ring-blue-500 rounded"
      >
        <div className="mb-1 flex items-center gap-2">
          <span className={`inline-block rounded px-2 py-0.5 text-xs font-medium ${badge.cls}`}>
            {badge.label}
          </span>
          <span className="truncate text-xs text-slate-500 dark:text-slate-400">
            {hit.url}
          </span>
        </div>

        <h3 className="mb-1 text-lg font-semibold text-blue-700 dark:text-blue-300">
          {hit.title}
        </h3>

        <p
          className="text-sm text-slate-700 dark:text-slate-300 [&_mark]:bg-yellow-200 [&_mark]:text-inherit dark:[&_mark]:bg-yellow-500/40"
          dangerouslySetInnerHTML={{ __html: safeSnippet }}
        />
      </a>
    </li>
  );
}
```

## Why DOMPurify

The backend emits HTML like:
```html
…rollback procedure for <mark>kubernetes</mark> deployments…
```

Rendering via `dangerouslySetInnerHTML` without sanitization is an XSS vector
if backend logic ever changes. DOMPurify with `ALLOWED_TAGS: ['mark']`
enforces a strict allow-list — any `<script>`, `<img onerror=…>`, `<a href=…>`
injection is stripped.

## Styling `<mark>` with Arbitrary Selector

Tailwind's `[&_mark]:…` syntax targets descendant `<mark>` elements without a
stylesheet or `@apply`:

```html
<p class="[&_mark]:bg-yellow-200 dark:[&_mark]:bg-yellow-500/40">
```

Equivalent CSS: `p mark { background: #fde68a; }`.

## Keyboard Navigation

The whole card is wrapped in `<a>` with:
- `focus:ring-2 focus:ring-blue-500` — visible focus state
- `rel="noopener noreferrer"` — safe external link
- `target="_blank"` — opens source in new tab (users want to compare)

## Source-Specific Link Behavior (Optional)

If ADO links should open in the same tab (user is likely already authed), branch:

```tsx
const target = hit.source === 'ado' ? '_self' : '_blank';
```

## Testing

```tsx
// ResultItem.test.tsx
import { render, screen } from '@testing-library/react';
import { ResultItem } from './ResultItem';

test('renders mark but strips script', () => {
  const hit = {
    id: '1', title: 'Test', url: 'https://x/y', source: 'ado' as const,
    score: 1.0,
    snippet: 'hello <mark>world</mark><script>alert(1)</script>',
  };
  render(<ResultItem hit={hit} />);
  expect(screen.getByText('world').tagName).toBe('MARK');
  expect(document.querySelector('script')).toBeNull();
});
```

## Common Mistakes

| Wrong | Right |
|-------|-------|
| `dangerouslySetInnerHTML` without sanitizer | Always `DOMPurify.sanitize` first |
| Allowing `<a>` in snippet | Backend must not emit links inside snippets |
| Hardcoded badge colors | Use the `BADGE` map so dark-mode variants match |
| Forgetting `rel="noopener"` on external links | Always set for `target="_blank"` |

## Related

- [search-page-component.md](search-page-component.md) — parent that renders this
- [api-client-typed.md](api-client-typed.md) — the `SearchHit` type
- `sqlite-fts5/patterns/snippets-highlighting.md` — upstream snippet generator
