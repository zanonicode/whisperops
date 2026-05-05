# Pattern: SQLite Index Persistence on AWS Lambda

> **Purpose**: Keep the FTS5 index available across Lambda cold/warm invocations without rebuilding
> **MCP Validated**: 2026-04-23

## When to Use

- Running the search API on AWS Lambda
- Index size > a few MB (too big to embed in deployment package)
- You want fast cold starts despite a large index

## The Problem

- **Lambda `/tmp`** persists across *warm* invocations but wipes on *cold* start
- **Deployment package** is capped at 250 MB unzipped — too small for large indexes
- **Rebuilding on every cold start** adds seconds of latency

## The Solution: S3 Snapshot + `/tmp` Cache

```python
"""Hydrate SQLite FTS5 index from S3 tarball on cold start; reuse on warm."""
from __future__ import annotations

import os
import sqlite3
import tarfile
import time
from pathlib import Path

import boto3

S3_BUCKET = os.environ["INDEX_BUCKET"]         # e.g. "devops-wiki-search-index"
S3_KEY = os.environ.get("INDEX_KEY", "search.db.tar.gz")
LOCAL_DB = Path("/tmp/search.db")
SENTINEL = Path("/tmp/.index-ready")

_db: sqlite3.Connection | None = None


def get_db() -> sqlite3.Connection:
    """Return a warm SQLite connection, hydrating from S3 if cold."""
    global _db
    if _db is not None:
        return _db

    if not SENTINEL.exists():
        _download_and_extract()
        SENTINEL.touch()

    _db = sqlite3.connect(str(LOCAL_DB))
    _db.row_factory = sqlite3.Row
    return _db


def _download_and_extract() -> None:
    """Pull the index tarball from S3 and unpack to /tmp."""
    s3 = boto3.client("s3")
    tar_path = Path("/tmp/search.db.tar.gz")

    t0 = time.monotonic()
    s3.download_file(S3_BUCKET, S3_KEY, str(tar_path))
    with tarfile.open(tar_path, "r:gz") as tar:
        tar.extractall("/tmp")
    tar_path.unlink(missing_ok=True)

    print(f"Index hydrated in {time.monotonic() - t0:.2f}s")
```

## Configuration

| Setting | Default | Description |
|---------|---------|-------------|
| `INDEX_BUCKET` | env var | S3 bucket containing the tarball |
| `INDEX_KEY` | `search.db.tar.gz` | Object key |
| `LOCAL_DB` | `/tmp/search.db` | Unpacked DB location |
| `/tmp` size | 512 MB default, 10 GB max | Configure in Lambda settings if needed |

## Index Build Pipeline (Separate Lambda)

The search API Lambda is read-only. A second Lambda (triggered by ADO webhook or cron) rebuilds and uploads:

```python
"""Build index locally, compress, push to S3 — runs periodically."""
from pathlib import Path
import tarfile, sqlite3, tempfile, boto3
from mypkg.indexer import index_directory
from mypkg.ado_sync import sync_wiki

def rebuild_and_publish():
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        # 1. Clone ADO wiki
        sync_wiki(os.environ["ADO_URL"], tmp / "wiki")
        # 2. Build FTS5 index
        db = sqlite3.connect(tmp / "search.db")
        index_directory(db, tmp / "wiki")
        db.close()
        # 3. Tar + gzip
        with tarfile.open(tmp / "search.db.tar.gz", "w:gz") as tar:
            tar.add(tmp / "search.db", arcname="search.db")
        # 4. Upload
        boto3.client("s3").upload_file(
            str(tmp / "search.db.tar.gz"),
            os.environ["INDEX_BUCKET"],
            "search.db.tar.gz",
        )
```

## Cold-Start Benchmark

| Index size | Download time | Total cold-start delta |
|-----------|---------------|-----------------------|
| 10 MB | ~100ms | ~300ms |
| 50 MB | ~400ms | ~700ms |
| 200 MB | ~1.5s | ~2s |

Keep the index under 100 MB for acceptable cold-start latency.

## Example Usage

```python
# In your FastAPI/Mangum handler
from fastapi import FastAPI
from mypkg.index_cache import get_db
from mypkg.search import search

app = FastAPI()

@app.get("/search")
def search_endpoint(q: str):
    db = get_db()   # warm: instant; cold: ~500ms hydration
    hits = search(db, q, limit=20)
    return [h.__dict__ for h in hits]
```

## See Also

- [index-markdown](index-markdown.md) — how the index is built
- `aws-serverless-web` KB (upcoming) — Lambda deployment details
