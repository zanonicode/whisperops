# Docker Compose Local Dev — Quick Reference

> Fast lookup. For runnable snippets, see [patterns/](patterns/).

## Service Cheat Sheet

| Service | Start | Role | Notes |
|---------|-------|------|-------|
| `frontend` | `docker compose up frontend` | Vite dev on :5173 | bind-mount `./src` for HMR |
| `backend` | `docker compose up backend` | Uvicorn on :8000 | bind-mount `./backend`; volume `wiki-index:ro` |
| `indexer` | `docker compose run --rm indexer` | One-shot index rebuild | `profiles: [index]` — not started by `up` |

## Command Recipes

| Goal | Command |
|------|---------|
| Start foreground | `docker compose up` |
| Start detached | `docker compose up -d` |
| Rebuild index | `docker compose run --rm indexer` |
| Tail backend logs | `docker compose logs -f backend` |
| Stop (keep data) | `docker compose down` |
| Nuke volumes | `docker compose down -v` |
| Shell into backend | `docker compose exec backend bash` |
| PC-003 smoke test | `docker compose run --rm backend python -c "from app.lambda_handler import handler; from app.main import app; print('ok')"` |

## Volume Map

| Volume | Type | Mounted in | Mode |
|--------|------|-----------|------|
| `wiki-index` | named | `backend:/data`, `indexer:/data` | `ro` / `rw` |
| `ado-clone` | named | `indexer:/clone` | `rw` |
| `./src` | bind | `frontend:/app/src` | `rw` (host) |
| `./backend` | bind | `backend:/app` | `rw` (host) |

## `.env` Variable Map

| Variable | Consumer | Required |
|----------|----------|----------|
| `ENTRA_TENANT_ID` | frontend, backend | ✅ |
| `ENTRA_CLIENT_ID` | frontend, backend | ✅ |
| `ENTRA_API_AUDIENCE` | backend | ✅ |
| `ADO_PAT` | indexer | ✅ |
| `ADO_WIKI_REPO_URL` | indexer | ✅ |
| `PLATFORM_WIKI_BASE` | backend | ✅ |
| `DISCOURSE_BASE` | backend | ✅ |
| `DISCOURSE_API_KEY` | backend | optional |
| `CORS_ALLOW_ORIGIN` | backend | ✅ (`http://localhost:5173`) |
| `FTS5_DB_PATH` | backend, indexer | ✅ (`/data/wiki.db`) |
| `HTTPS_PROXY` / `NO_PROXY` | backend, indexer | if VPN |

## Common Pitfalls

| Don't | Do |
|-------|----|
| Bake `ADO_PAT` into Dockerfile `ENV` | Pass via `.env` + compose `environment:` |
| Run `indexer` as root, `backend` as non-root on same volume | Pin both to UID 1000, or `chown` on indexer exit |
| Use `CORS_ALLOW_ORIGIN=*` "just for local" | Explicit `http://localhost:5173` — same pattern prod needs |
| Copy `.env` into the image | Mount at runtime; keep `.env` in `.dockerignore` |
| Install dev deps into the runtime image | Multi-stage build or `requirements-dev.txt` separation |
| Poll-based watch for Vite on macOS | Use `CHOKIDAR_USEPOLLING=true` only if bind-mount HMR fails |

## Related Files

| Topic | Path |
|-------|------|
| Full compose file | `patterns/three-service-compose.md` |
| Dockerfiles | `patterns/uv-dockerfile.md` |
| CORS setup | `patterns/compose-cors.md` |
| Hot reload quirks | `patterns/hot-reload-setup.md` |
