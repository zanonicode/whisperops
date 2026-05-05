# Docker Compose Local Dev — Knowledge Base

> **MCP Validated:** 2026-04-24
> **Scope:** Laptop-local `docker compose` stack for the DevOps Wiki prototype. Three services (`frontend`, `backend`, `indexer`), named volumes for the SQLite FTS5 index, hot reload on both sides, `.env`-driven secrets. Covers the prototype requirements in [notes/02-local-docker-prototype.md](../../../notes/02-local-docker-prototype.md).

## Why This KB Exists

The production KBs (`fastapi-lambda`, `aws-serverless-web`, `react-search-ui`) assume AWS deployment. The prototype runs everywhere-but-AWS and introduces risks that never appear in production:

| Prototype-only concern | Covered here |
|------------------------|--------------|
| CORS between `:5173` ↔ `:8000` (R-P2) | patterns/compose-cors.md |
| `HTTPS_PROXY` pass-through inside containers (R-P3) | patterns/proxy-passthrough.md |
| Volume permission mismatch `indexer` (root) vs `backend` (non-root) (R-P5) | concepts/volumes-and-uids.md |
| Vite HMR websocket inside Docker (R-P7) | patterns/hot-reload-setup.md |
| Secret hygiene — no PAT in image layers (R-P4, PC-005) | concepts/secrets-hygiene.md |
| `uv` inside `python:3.12-slim` with layer caching | patterns/uv-dockerfile.md |
| One-shot indexer via `profiles:` (PD6) | patterns/three-service-compose.md |

## The Prototype Stack (from PC-002)

| Service | Image | Port | Role |
|---------|-------|------|------|
| `frontend` | `node:20-alpine` | 5173 | Vite dev server, React SPA, hot reload |
| `backend` | `python:3.12-slim` | 8000 | FastAPI under Uvicorn `--reload` |
| `indexer` | `python:3.12-slim` | — | One-shot: clone ADO wiki + build FTS5 DB |

## Contents

### Concepts (what & why)

| File | Topic |
|------|-------|
| [concepts/compose-services.md](concepts/compose-services.md) | Service model, networks, `depends_on`, `profiles:` |
| [concepts/volumes-and-uids.md](concepts/volumes-and-uids.md) | Named vs bind volumes; UID alignment across services |
| [concepts/secrets-hygiene.md](concepts/secrets-hygiene.md) | `.env` contract, `.gitignore`/`.dockerignore`, no secrets in layers |

### Patterns (copy-paste recipes)

| File | Topic |
|------|-------|
| [patterns/three-service-compose.md](patterns/three-service-compose.md) | Full `docker-compose.yml` for frontend+backend+indexer |
| [patterns/hot-reload-setup.md](patterns/hot-reload-setup.md) | Vite HMR + Uvicorn `--reload` wiring + bind mounts |
| [patterns/uv-dockerfile.md](patterns/uv-dockerfile.md) | `python:3.12-slim` + `uv sync --frozen` + non-root user |
| [patterns/proxy-passthrough.md](patterns/proxy-passthrough.md) | Forward `HTTPS_PROXY` from host into containers |
| [patterns/compose-cors.md](patterns/compose-cors.md) | FastAPI `CORSMiddleware` driven by `CORS_ALLOW_ORIGIN` env |

## Quick Start

```bash
cp .env.example .env                  # fill in ENTRA_TENANT_ID, ADO_PAT, ...
docker compose up                     # frontend + backend, hot reload both
docker compose run --rm indexer       # one-shot: rebuild FTS5 index
docker compose down                   # keeps the wiki-index volume
docker compose down -v                # nukes the volume too
```

## Prototype Done Criteria (from §7 of the plan)

- `docker compose up` brings frontend + backend online with no manual steps beyond populating `.env`.
- SPA on `http://localhost:5173` triggers real MSAL.js login against the tenant.
- `/search?q=...` fans out to all 3 sources.
- Index rebuild = single command.
- No secret appears in repo, image layers, or container `env`-dump.
- **PC-003:** the same FastAPI `app` object runs under Uvicorn in the container AND wraps with Mangum for Lambda — verified by a smoke test importing from both entry points.

## Related KBs

- [fastapi-lambda](../fastapi-lambda/index.md) — FastAPI app object (shared with prototype via PC-003); see `concepts/uvicorn-local.md` there for the local-only entry point
- [react-search-ui](../react-search-ui/index.md) — Vite + React SPA; see `concepts/vite-docker-hmr.md` for the Docker-specific HMR notes
- [azure-devops-wiki](../azure-devops-wiki/index.md) — ADO clone patterns used by the `indexer` service
- [sqlite-fts5](../sqlite-fts5/index.md) — DB shape for the shared `wiki-index` volume
- [microsoft-sso](../microsoft-sso/index.md) — `http://localhost:5173` redirect URI is the key Entra-side change
