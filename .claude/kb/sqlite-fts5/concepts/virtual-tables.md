# FTS5 Virtual Tables

> **Purpose**: Declaring searchable indexes in SQLite via `CREATE VIRTUAL TABLE ... USING fts5(...)`
> **Confidence**: HIGH
> **MCP Validated**: 2026-04-23

## Overview

FTS5 is a SQLite extension that provides full-text search through "virtual tables" — SQL-queryable indexes backed by inverted index structures. You declare columns to index, insert rows like a normal table, and query with the `MATCH` operator. Python 3.12 stdlib `sqlite3` ships with FTS5 enabled.

## The Pattern

```python
import sqlite3

db = sqlite3.connect("search.db")

# Plain FTS5 table — data stored twice (once in FTS index, once in shadow tables)
db.executescript("""
    CREATE VIRTUAL TABLE IF NOT EXISTS pages USING fts5(
        title,
        body,
        source UNINDEXED,          -- stored but not tokenized
        tokenize = 'unicode61 remove_diacritics 2'
    );
""")
```

## External-Content Tables (Space Efficient)

When the canonical data already lives in a regular table, use external-content mode — FTS5 stores only the inverted index, cutting storage roughly in half:

```python
db.executescript("""
    CREATE TABLE docs (
        id INTEGER PRIMARY KEY,
        title TEXT,
        body TEXT,
        source TEXT
    );

    CREATE VIRTUAL TABLE pages USING fts5(
        title, body,
        content = 'docs',
        content_rowid = 'id',
        tokenize = 'unicode61 remove_diacritics 2'
    );
""")
```

Then sync via triggers or manual `INSERT INTO pages(rowid, title, body) SELECT id, title, body FROM docs`.

## Quick Reference

| Column Modifier | Effect |
|-----------------|--------|
| (none) | Tokenized + indexed + retrievable |
| `UNINDEXED` | Stored, retrievable, NOT searchable |
| `content=''` | No content stored — caller must provide via triggers |
| `prefix='2 3'` | Build prefix index for 2- and 3-char prefixes (faster prefix queries) |

## Common Mistakes

### Wrong

```python
# Treating FTS5 table like a normal table
db.execute("SELECT * FROM pages WHERE body LIKE '%kubernetes%'")
# Works but doesn't use the FTS index — O(n) scan
```

### Correct

```python
# Use MATCH to hit the inverted index
db.execute("SELECT * FROM pages WHERE pages MATCH 'kubernetes'")
```

## When to Use Each Mode

| Mode | Use When |
|------|----------|
| Plain (default) | Simple cases, <10k docs, storage not critical |
| External-content | >10k docs, or you already have a canonical table |
| Contentless (`content=''`) | Index from external source; never retrieve body from FTS |

## Related

- [tokenizers](tokenizers.md) — what `tokenize=` controls
- [index-markdown](../patterns/index-markdown.md) — full example
