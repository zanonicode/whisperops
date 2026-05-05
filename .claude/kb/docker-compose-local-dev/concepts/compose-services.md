# Compose Services, Networks, and Profiles

> **Purpose:** Explain the three-service topology, how services resolve each other, and why the indexer uses `profiles:`.
> **Confidence:** 0.95
> **MCP Validated:** 2026-04-24

## Overview

Docker Compose creates a default bridge network per project. Every service is reachable at `http://<service-name>:<port>` from every other service. That name-based DNS is the backbone of the prototype — frontend reaches backend via `http://backend:8000`, indexer and backend share a volume but never talk over HTTP.

## The Topology

```text
         host: http://localhost:5173         host: http://localhost:8000
                     │                                   │
                     │ published                         │ published
           ┌─────────▼──────────┐              ┌─────────▼──────────┐
           │     frontend       │   network    │      backend       │
           │  node:20-alpine    │◄────────────►│  python:3.12-slim  │
           │  Vite :5173        │   "devops"   │  Uvicorn :8000     │
           └────────────────────┘              └─────────┬──────────┘
                                                         │
                                                  volume │ wiki-index:ro
                                                         ▼
                                               ┌─────────────────────┐
                                               │      indexer        │
                                               │  python:3.12-slim   │
                                               │   profile: index    │
                                               └─────────────────────┘
```

## Network Rules

| Flow | Works? | Notes |
|------|--------|-------|
| Browser → `http://localhost:5173` | ✅ | Published port |
| Browser → `http://localhost:8000` | ✅ | Published port (used for CORS'd fetch from SPA) |
| `frontend` container → `backend:8000` | ✅ | Compose DNS; NOT used — browser talks to backend directly |
| `backend` → `https://login.microsoftonline.com` | ✅ | Egress via Docker NAT (may need proxy) |
| `backend` → `host.docker.internal` | avoid | Portability: only works on Desktop, breaks on Linux CI |

**Rule:** the browser is always the CORS origin, never the `frontend` container. So `CORS_ALLOW_ORIGIN=http://localhost:5173`.

## Why `profiles:` for the Indexer

Running `docker compose up` should NOT start the indexer. The indexer is a one-shot, possibly long-running, possibly credential-requiring job. `profiles:` tells Compose to exclude it unless explicitly requested:

```yaml
services:
  indexer:
    profiles: ["index"]   # excluded from `up`
    # ...
```

Run with `docker compose run --rm indexer`. `run` always honors the profile; `up` skips profiled services by default. `--rm` removes the stopped container, which matters because an indexer left behind keeps bind mounts busy.

## `depends_on` — What It Actually Guarantees

| Condition | Waits for |
|-----------|-----------|
| `service_started` | Container running (not healthy) |
| `service_healthy` | Healthcheck passing |
| `service_completed_successfully` | One-shot container exited 0 |

The prototype does **not** need `depends_on` between `frontend` and `backend` — the SPA retries in the browser. It does need `service_completed_successfully` if you ever chain `indexer → backend`, but the prototype's model is the indexer runs explicitly and ahead of time.

## Common Mistakes

### Wrong

```yaml
services:
  backend:
    network_mode: host   # bypasses Compose DNS + CORS planning
```

### Correct

```yaml
services:
  backend:
    ports:
      - "8000:8000"      # publish explicitly
    # default network — uses compose DNS
```

Never reach for `network_mode: host` to "fix" a CORS issue. CORS is a browser policy — the network mode doesn't change what the browser enforces.

## Related

- [volumes-and-uids](volumes-and-uids.md)
- [secrets-hygiene](secrets-hygiene.md)
- [patterns/three-service-compose](../patterns/three-service-compose.md)
