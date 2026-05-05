# FTS5 BM25 Ranking

> **Purpose**: Ranking FTS5 search results by relevance using BM25
> **Confidence**: HIGH
> **MCP Validated**: 2026-04-23

## Overview

BM25 is the industry-standard relevance scoring function — it weights token matches by term frequency, document length, and corpus rarity. FTS5 exposes it as the `bm25()` function inside SQL queries. **Lower scores mean more relevant** (it's a negative-log score). You can also assign per-column weights, e.g. to boost title matches over body matches.

## The Pattern

```python
import sqlite3

db = sqlite3.connect("search.db")

# Basic ranking — lower bm25() first
results = db.execute("""
    SELECT title, source, bm25(pages) AS score
    FROM pages
    WHERE pages MATCH ?
    ORDER BY bm25(pages)
    LIMIT 20
""", (query,)).fetchall()
```

## Quick Reference

| Call | Effect |
|------|--------|
| `bm25(pages)` | Default weights (1.0 per column) |
| `bm25(pages, 10.0, 1.0)` | Title (col 0) weighted 10×, body (col 1) weighted 1× |
| `bm25(pages, 10.0, 1.0, 0.0)` | Weight 0 for col 2 = ignore that column in score |

## Per-Column Weighting

Typically you want title matches to dominate:

```python
# Schema: fts5(title, body, source UNINDEXED)
results = db.execute("""
    SELECT title,
           snippet(pages, 1, '<b>', '</b>', '…', 20) AS preview,
           bm25(pages, 10.0, 1.0) AS score
    FROM pages
    WHERE pages MATCH ?
    ORDER BY bm25(pages, 10.0, 1.0)
    LIMIT 20
""", (query,)).fetchall()
```

**Rule of thumb for doc search:**

| Column | Weight | Rationale |
|--------|--------|-----------|
| `title` | 10.0 | Strong signal of topicality |
| `headings` | 5.0 | Subtopic signal |
| `body` | 1.0 | Baseline |
| `code` | 0.5 | Often noisy (variable names, boilerplate) |

## Combining with Business Signals

BM25 gives raw relevance. For final ranking, often combine with freshness or source trust:

```python
# Boost recent pages; attenuate stale ones
results = db.execute("""
    SELECT title,
           (bm25(pages, 10.0, 1.0)
            - 0.01 * julianday('now', '-90 days', 'start of day')
            + 0.01 * julianday(updated_at)
           ) AS final_score
    FROM pages
    WHERE pages MATCH ?
    ORDER BY final_score
    LIMIT 20
""", (query,)).fetchall()
```

## Common Mistakes

### Wrong

```python
# Treating higher as better
ORDER BY bm25(pages) DESC   -- returns least relevant first!
```

### Correct

```python
ORDER BY bm25(pages) ASC    -- lower = more relevant
# ASC is default, so just:
ORDER BY bm25(pages)
```

## Ranking Sanity Check

- If scores are all near 0, the index is small or queries are too broad
- If top results look wrong, check column weights first — body often drowns out title
- If scores aren't monotonic, you probably added a `WHERE` that breaks index use

## Related

- [virtual-tables](virtual-tables.md) — column order determines bm25 arg order
- [snippets-highlighting](../patterns/snippets-highlighting.md) — pair with ranking for UX
