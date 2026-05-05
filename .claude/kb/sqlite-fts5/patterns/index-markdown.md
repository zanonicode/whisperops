# Pattern: Index Markdown Files into FTS5

> **Purpose**: Build a searchable index from a directory of `.md` files
> **MCP Validated**: 2026-04-23

## When to Use

- Initial population of the ADO wiki search index
- Rebuilding after tokenizer change
- Local development / testing

## Implementation

```python
"""Index a tree of Markdown files into SQLite FTS5."""
from __future__ import annotations

import re
import sqlite3
from pathlib import Path

import markdown_it  # pip install markdown-it-py


SCHEMA = """
    CREATE TABLE IF NOT EXISTS docs (
        id INTEGER PRIMARY KEY,
        rel_path TEXT UNIQUE NOT NULL,
        title TEXT NOT NULL,
        body TEXT NOT NULL,
        source TEXT NOT NULL DEFAULT 'ado-wiki',
        updated_at TEXT NOT NULL
    );

    CREATE VIRTUAL TABLE IF NOT EXISTS pages USING fts5(
        title, body, source UNINDEXED,
        content = 'docs',
        content_rowid = 'id',
        tokenize = 'unicode61 remove_diacritics 2'
    );

    CREATE TRIGGER IF NOT EXISTS docs_ai AFTER INSERT ON docs BEGIN
        INSERT INTO pages(rowid, title, body, source)
        VALUES (new.id, new.title, new.body, new.source);
    END;

    CREATE TRIGGER IF NOT EXISTS docs_au AFTER UPDATE ON docs BEGIN
        INSERT INTO pages(pages, rowid, title, body, source)
        VALUES('delete', old.id, old.title, old.body, old.source);
        INSERT INTO pages(rowid, title, body, source)
        VALUES (new.id, new.title, new.body, new.source);
    END;

    CREATE TRIGGER IF NOT EXISTS docs_ad AFTER DELETE ON docs BEGIN
        INSERT INTO pages(pages, rowid, title, body, source)
        VALUES('delete', old.id, old.title, old.body, old.source);
    END;
"""


def markdown_to_text(md: str) -> str:
    """Strip Markdown syntax to plain text for indexing."""
    # Drop code fences and inline code (often noisy)
    md = re.sub(r"```[\s\S]*?```", " ", md)
    md = re.sub(r"`[^`]+`", " ", md)
    # Strip links: [text](url) → text
    md = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", md)
    # Strip emphasis markers
    md = re.sub(r"[*_#>]+", " ", md)
    return re.sub(r"\s+", " ", md).strip()


def extract_title(md: str, fallback: str) -> str:
    """First H1 wins; else use fallback (filename)."""
    for line in md.splitlines():
        if line.startswith("# "):
            return line[2:].strip()
    return fallback


def index_directory(db: sqlite3.Connection, root: Path, source: str = "ado-wiki") -> int:
    """Index every .md file under root. Returns count."""
    db.executescript(SCHEMA)
    count = 0

    for md_path in root.rglob("*.md"):
        rel_path = str(md_path.relative_to(root).with_suffix(""))
        raw = md_path.read_text(encoding="utf-8", errors="replace")
        title = extract_title(raw, rel_path.rsplit("/", 1)[-1].replace("-", " "))
        body = markdown_to_text(raw)
        updated = md_path.stat().st_mtime

        db.execute(
            """INSERT INTO docs (rel_path, title, body, source, updated_at)
               VALUES (?, ?, ?, ?, datetime(?, 'unixepoch'))
               ON CONFLICT(rel_path) DO UPDATE SET
                 title = excluded.title,
                 body = excluded.body,
                 updated_at = excluded.updated_at""",
            (rel_path, title, body, source, updated),
        )
        count += 1

    db.commit()
    return count
```

## Configuration

| Setting | Default | Description |
|---------|---------|-------------|
| `tokenize` | `unicode61 remove_diacritics 2` | Change to add `porter` for English stemming |
| `source` | `"ado-wiki"` | Distinguish docs when merging multiple sources later |
| File encoding | `utf-8` w/ `errors='replace'` | Don't crash on weird encoding |

## Example Usage

```python
import sqlite3
from pathlib import Path
from mypkg.indexer import index_directory

db = sqlite3.connect("/tmp/search.db")
n = index_directory(db, Path("/tmp/wiki"), source="ado-wiki")
print(f"Indexed {n} pages")

# Query
for row in db.execute("""
    SELECT title, snippet(pages, 1, '<b>', '</b>', '…', 20), bm25(pages, 10.0, 1.0)
    FROM pages WHERE pages MATCH ?
    ORDER BY bm25(pages, 10.0, 1.0) LIMIT 10
""", ("kubernetes deploy",)):
    print(row)
```

## See Also

- [snippets-highlighting](snippets-highlighting.md) — for the search-result UX
- [lambda-persistence](lambda-persistence.md) — deploying the DB to Lambda
