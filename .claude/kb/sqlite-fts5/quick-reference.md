# SQLite FTS5 Quick Reference

> Common queries. Python 3.12 stdlib `sqlite3` only.

## Create Index

| Goal | SQL |
|------|-----|
| Basic FTS5 table | `CREATE VIRTUAL TABLE pages USING fts5(title, body, source UNINDEXED);` |
| With tokenizer | `... USING fts5(title, body, tokenize='unicode61 remove_diacritics 2');` |
| External content | `... USING fts5(title, body, content='docs', content_rowid='id');` |

## Query Syntax (inside `MATCH '...'`)

| Pattern | Example | Meaning |
|---------|---------|---------|
| Plain | `deployment` | Token match anywhere |
| Phrase | `"rolling release"` | Exact adjacent tokens |
| Prefix | `deploy*` | Tokens starting with `deploy` |
| Column | `title:kubernetes` | Only in `title` column |
| AND | `kubernetes helm` | Both tokens (default) |
| OR | `kubernetes OR helm` | Either |
| NOT | `kubernetes NOT azure` | Exclude |
| NEAR | `NEAR(deploy rollback, 5)` | Within 5 tokens |

## Result Helpers

| Function | Returns |
|----------|---------|
| `snippet(pages, 1, '<b>', '</b>', '…', 20)` | Highlighted snippet from body column |
| `highlight(pages, 0, '<b>', '</b>')` | Full column with matches wrapped |
| `bm25(pages)` | Relevance score (lower = better) |
| `bm25(pages, 10.0, 1.0)` | Title weighted 10× body |

## Tokenizer Choice

| Tokenizer | When |
|-----------|------|
| `unicode61 remove_diacritics 2` | **Default** — good Unicode, strips accents |
| `porter unicode61` | Add English stemming (deploy/deploying → same stem) |
| `trigram` | Fuzzy / typo-tolerant, larger index |

## Python Basics

```python
import sqlite3
db = sqlite3.connect("search.db")
db.executescript("""
    CREATE VIRTUAL TABLE IF NOT EXISTS pages USING fts5(
        title, body, source UNINDEXED,
        tokenize='unicode61 remove_diacritics 2'
    );
""")
db.execute("INSERT INTO pages VALUES (?, ?, ?)", (title, body, source))
db.commit()

for row in db.execute(
    "SELECT title, snippet(pages, 1, '<b>', '</b>', '…', 15), bm25(pages) "
    "FROM pages WHERE pages MATCH ? ORDER BY bm25(pages) LIMIT 20",
    (query,)
):
    print(row)
```

## Common Pitfalls

| Don't | Do |
|-------|-----|
| Use `LIKE '%kw%'` for search | Use `MATCH 'kw'` — uses the index |
| Forget `tokenize=` on CREATE | Set `unicode61 remove_diacritics 2` explicitly |
| Rank with `ORDER BY rank` | Use `ORDER BY bm25(table) ASC` (lower = better) |
| Rebuild index on every write | Use incremental `INSERT/UPDATE/DELETE` |

## Related

| Topic | Path |
|-------|------|
| Index from Markdown | `patterns/index-markdown.md` |
| Lambda persistence | `patterns/lambda-persistence.md` |
| Full Index | `index.md` |
