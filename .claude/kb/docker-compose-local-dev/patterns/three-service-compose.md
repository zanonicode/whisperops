# Three-Service `docker-compose.yml`

> **Purpose:** Production-shaped compose file for the DevOps Wiki prototype: frontend + backend + one-shot indexer, with named volumes, profiles, `.env` injection, and hot reload.
> **MCP Validated:** 2026-04-24

## When to Use

- Starting the prototype from scratch (Day 1 deliverable)
- Replacing an ad-hoc dev setup with `docker compose up` as single entry point
- Pinning UID alignment between `indexer` and `backend` so they can share the FTS5 volume safely

## Implementation

```yaml
# docker-compose.yml
name: devops-wiki

services:

  frontend:
    build:
      context: .
      dockerfile: Dockerfile.frontend
    ports:
      - "5173:5173"
    environment:
      VITE_API_BASE:         "http://localhost:8000"
      VITE_ENTRA_TENANT_ID:  ${ENTRA_TENANT_ID}
      VITE_ENTRA_CLIENT_ID:  ${ENTRA_CLIENT_ID}
      VITE_ENTRA_AUDIENCE:   ${ENTRA_API_AUDIENCE}
      # macOS HMR fallback — leave commented unless bind-mount watch fails
      # CHOKIDAR_USEPOLLING: "true"
    volumes:
      - ./src:/app/src
      - ./index.html:/app/index.html
      - ./vite.config.ts:/app/vite.config.ts
      - ./package.json:/app/package.json
      - ./tsconfig.json:/app/tsconfig.json
      # NOT mounted: node_modules lives in the image
    command: ["npm", "run", "dev", "--", "--host", "0.0.0.0"]

  backend:
    build:
      context: .
      dockerfile: Dockerfile.backend
    ports:
      - "8000:8000"
    environment:
      CORS_ALLOW_ORIGIN:   ${CORS_ALLOW_ORIGIN}
      ENTRA_TENANT_ID:     ${ENTRA_TENANT_ID}
      ENTRA_CLIENT_ID:     ${ENTRA_CLIENT_ID}
      ENTRA_API_AUDIENCE:  ${ENTRA_API_AUDIENCE}
      PLATFORM_WIKI_BASE:  ${PLATFORM_WIKI_BASE}
      DISCOURSE_BASE:      ${DISCOURSE_BASE}
      DISCOURSE_API_KEY:   ${DISCOURSE_API_KEY:-}
      FTS5_DB_PATH:        ${FTS5_DB_PATH:-/data/wiki.db}
      HTTPS_PROXY:         ${HTTPS_PROXY:-}
      NO_PROXY:            ${NO_PROXY:-}
    volumes:
      - ./backend:/app
      - wiki-index:/data:ro
    command: ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000", "--reload"]

  indexer:
    profiles: ["index"]
    build:
      context: .
      dockerfile: Dockerfile.backend        # reuse image; different command
    environment:
      ADO_PAT:           ${ADO_PAT}
      ADO_WIKI_REPO_URL: ${ADO_WIKI_REPO_URL}
      FTS5_DB_PATH:      ${FTS5_DB_PATH:-/data/wiki.db}
      HTTPS_PROXY:       ${HTTPS_PROXY:-}
      NO_PROXY:          ${NO_PROXY:-}
    volumes:
      - wiki-index:/data
      - ado-clone:/clone
    command: ["python", "-m", "app.index_build"]

volumes:
  wiki-index:
  ado-clone:
```

## Configuration

| Setting | Default | Description |
|---------|---------|-------------|
| `CORS_ALLOW_ORIGIN` | `http://localhost:5173` | Exact origin the backend trusts |
| `FTS5_DB_PATH` | `/data/wiki.db` | Path inside backend + indexer containers |
| `profiles: ["index"]` on `indexer` | — | Excludes from `docker compose up`; run via `docker compose run --rm indexer` |
| `:ro` on backend's `wiki-index` | — | Defense-in-depth against a bug that tries to write |
| `VITE_*` env | — | Must be prefixed `VITE_` for Vite to expose them to client code |

## Example Usage

```bash
cp .env.example .env                        # fill ADO_PAT, tenant/client IDs

docker compose up                           # frontend + backend, hot reload both
docker compose run --rm indexer             # rebuild FTS5 index on demand
docker compose logs -f backend              # tail logs
docker compose down                         # stop; keep the volume
docker compose down -v                      # nuke the index too
```

## PC-003 Smoke Test

The prototype's dealbreaker is that the same `app` object ports to Lambda:

```bash
docker compose run --rm backend python -c \
  "from app.lambda_handler import handler; from app.main import app; print('ok')"
```

If this fails, Mangum or Lambda-only imports have leaked into the shared app module. See [../concepts/compose-services.md](../concepts/compose-services.md) for the service model this test validates.

## See Also

- [uv-dockerfile](uv-dockerfile.md)
- [hot-reload-setup](hot-reload-setup.md)
- [compose-cors](compose-cors.md)
- [proxy-passthrough](proxy-passthrough.md)
