# Pattern: Snippets and Highlighting

> **Purpose**: Produce search-result previews with matched terms highlighted
> **MCP Validated**: 2026-04-23

## When to Use

- Rendering search result cards with context around the match
- Showing users why a result matched their query
- Any time the full body text is too long to display

## Implementation

```python
"""Generate snippets and highlights for FTS5 search results."""
from __future__ import annotations

import sqlite3
from dataclasses import dataclass


@dataclass
class SearchHit:
    title: str
    snippet: str
    score: float
    source: str
    rel_path: str


def search(
    db: sqlite3.Connection,
    query: str,
    limit: int = 20,
    snippet_tokens: int = 20,
) -> list[SearchHit]:
    """Return ranked search results with highlighted snippets."""
    sql = """
        SELECT
            d.title,
            snippet(pages, 1, '<mark>', '</mark>', '…', ?) AS snippet,
            bm25(pages, 10.0, 1.0) AS score,
            d.source,
            d.rel_path
        FROM pages
        JOIN docs d ON d.id = pages.rowid
        WHERE pages MATCH ?
        ORDER BY bm25(pages, 10.0, 1.0)
        LIMIT ?
    """
    rows = db.execute(sql, (snippet_tokens, query, limit)).fetchall()
    return [
        SearchHit(title=r[0], snippet=r[1], score=r[2], source=r[3], rel_path=r[4])
        for r in rows
    ]
```

## `snippet()` Arguments

| Arg # | Arg | Description |
|-------|-----|-------------|
| 0 | `pages` | FTS5 table name |
| 1 | `1` | Column index to snippet from (0=title, 1=body) |
| 2 | `'<mark>'` | Open tag |
| 3 | `'</mark>'` | Close tag |
| 4 | `'…'` | Ellipsis text for truncation |
| 5 | `20` | Max tokens in snippet (per match region) |

## `highlight()` for Full Columns

Use when you want the entire column with matches wrapped (e.g. for title):

```python
sql = """
    SELECT
        highlight(pages, 0, '<mark>', '</mark>') AS title_hl,
        snippet(pages, 1, '<mark>', '</mark>', '…', 20) AS body_snippet
    FROM pages
    WHERE pages MATCH ?
"""
```

## Sanitizing HTML Tags

If body content may contain HTML, escape before highlighting:

```python
import html

def safe_snippet(raw_snippet: str) -> str:
    """Escape HTML then restore mark tags."""
    escaped = html.escape(raw_snippet)
    return (escaped
            .replace("&lt;mark&gt;", "<mark>")
            .replace("&lt;/mark&gt;", "</mark>"))
```

## Example Output

```python
from mypkg.search import search
import sqlite3

db = sqlite3.connect("/tmp/search.db")
hits = search(db, "kubernetes rollback")

for h in hits[:3]:
    print(f"[{h.score:.2f}] {h.title}")
    print(f"    {h.snippet}")
    print(f"    → {h.source}:{h.rel_path}\n")

# [1.23] Production Rollback
#     …rollback procedure for <mark>kubernetes</mark> deployments …
#     → ado-wiki:Deployment/Rollback
```

## Configuration

| Setting | Default | Description |
|---------|---------|-------------|
| `snippet_tokens` | `20` | Balance context vs. card size; 15-25 is sweet spot |
| Open/close tags | `<mark>` / `</mark>` | Semantic HTML; style with CSS |
| Ellipsis | `…` | Use Unicode char for clean display |

## See Also

- [index-markdown](index-markdown.md) — what produces the content that snippets come from
- [bm25-ranking](../concepts/bm25-ranking.md) — how results are ordered
