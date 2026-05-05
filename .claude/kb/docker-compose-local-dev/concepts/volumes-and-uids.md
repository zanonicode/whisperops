# Volumes, UIDs, and the Shared FTS5 Index

> **Purpose:** Explain how `indexer` and `backend` share the SQLite FTS5 file without permission collisions (R-P5), and when to pick a named volume vs a bind mount (QP2).
> **Confidence:** 0.95
> **MCP Validated:** 2026-04-24

## Overview

The prototype has two classes of shared state: the FTS5 index (`wiki-index` volume, shared between indexer and backend) and the ADO clone (`ado-clone` volume, used only by indexer). Named volumes are managed by Docker; bind mounts reflect a host path. The prototype default is **named volumes** — they isolate data from the host and make `docker compose down -v` a real reset button.

## Named Volume vs Bind Mount (QP2)

| Criterion | Named volume | Bind mount |
|-----------|--------------|------------|
| Host visibility | Hidden (under `/var/lib/docker`) | Direct (`./data`) |
| Debuggable with host tools | No | Yes (`sqlite3 ./data/wiki.db`) |
| Cleanup | `down -v` | `rm -rf ./data` |
| UID ownership control | Docker | Host UID wins |
| Portability | High | Lower (Windows path pain) |

**Prototype default:** named volume `wiki-index` for cleanliness. Override to bind mount only when debugging FTS5 queries from the host.

## The UID Problem (R-P5)

The default user in `python:3.12-slim` is `root` (UID 0). If the backend runs as a non-root user (recommended) but the indexer writes as root, the backend may not be able to read the DB on some filesystems.

### Three strategies — pick one

**A. Run both services as the same non-root UID**

```dockerfile
# Dockerfile.backend and Dockerfile.indexer share this tail
RUN useradd -u 1000 -m appuser
USER appuser
```

**B. Chown on indexer exit**

```yaml
services:
  indexer:
    command: >
      sh -c "python -m app.index_build && chown -R 1000:1000 /data"
```

**C. Loosen the volume**

```yaml
volumes:
  wiki-index:
    driver_opts:
      o: "uid=1000,gid=1000"
```

The prototype picks **A** — it's the least magic, matches production (Lambda runs as the Lambda user, not root), and avoids an extra command layer.

## Read-Only Mounts Are Cheap Safety

Backend never writes to the index. Mount it `ro`:

```yaml
services:
  backend:
    volumes:
      - wiki-index:/data:ro
  indexer:
    volumes:
      - wiki-index:/data       # rw implicit
```

If a bug in the backend tries to `CREATE INDEX`, it fails loudly with `attempt to write a readonly database` instead of corrupting the indexer's view.

## SQLite on Docker Volumes — Gotchas

| Gotcha | Fix |
|--------|-----|
| SQLite WAL files (`-wal`, `-shm`) outlive process | Keep them on the same volume; never split |
| `flock()` unreliable on some bind-mounted filesystems | Prefer named volume for SQLite |
| Two writers (indexer + backend) at once | Prototype: indexer is one-shot, so only one writer ever. Don't introduce a second. |

## Common Mistakes

### Wrong

```yaml
services:
  backend:
    volumes:
      - ./wiki.db:/data/wiki.db   # single-file bind — breaks WAL
```

### Correct

```yaml
services:
  backend:
    volumes:
      - wiki-index:/data:ro        # whole directory, named volume
```

## Related

- [compose-services](compose-services.md)
- [patterns/three-service-compose](../patterns/three-service-compose.md)
- [../../sqlite-fts5/index.md](../../sqlite-fts5/index.md)
