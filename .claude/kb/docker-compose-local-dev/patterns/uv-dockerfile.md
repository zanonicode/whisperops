# `uv`-Based Dockerfile for Python 3.12 Services

> **Purpose:** Build `backend` and `indexer` images from `python:3.12-slim` with `uv sync --frozen`, layer caching, and non-root user alignment. Covers PC-002 and R-P5.
> **MCP Validated:** 2026-04-24

## When to Use

- Any Python service in the prototype (`backend`, `indexer`)
- Anywhere you want fast rebuilds that don't re-install deps on every code change
- Anywhere you need the image to run as UID 1000 to share volumes with other services

## Implementation

### `Dockerfile.backend`

```dockerfile
# syntax=docker/dockerfile:1.7
FROM python:3.12-slim AS base

# uv is a single static binary; pin the version
COPY --from=ghcr.io/astral-sh/uv:0.4.30 /uv /uvx /usr/local/bin/

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    UV_SYSTEM_PYTHON=1 \
    UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy

WORKDIR /app

# ── Dependency layer (cacheable) ───────────────────────────────────────
# Copy ONLY the lockfile + manifest first so edits to app code don't bust
# the deps cache.
COPY pyproject.toml uv.lock ./
RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --frozen --no-install-project --no-dev

# ── App code layer (changes frequently) ────────────────────────────────
COPY backend/ /app/

# Non-root user that matches the indexer's UID so they can co-own /data
RUN useradd --system --uid 1000 --home-dir /app --shell /usr/sbin/nologin appuser \
 && chown -R appuser:appuser /app
USER appuser

EXPOSE 8000
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000", "--reload"]
```

### `Dockerfile.frontend`

```dockerfile
FROM node:20-alpine

WORKDIR /app

# Install deps first — cacheable unless package.json / lockfile changes
COPY package.json package-lock.json* ./
RUN npm ci

# Code copy is thin — real code arrives via bind mount in compose
COPY . .

EXPOSE 5173
CMD ["npm", "run", "dev", "--", "--host", "0.0.0.0"]
```

## Configuration

| Setting | Why |
|---------|-----|
| `--mount=type=cache,target=/root/.cache/uv` | Persists uv's wheel cache across rebuilds — big speedup |
| `UV_COMPILE_BYTECODE=1` | Pre-compiles `.pyc` at install, faster cold import |
| `UV_LINK_MODE=copy` | Avoids hardlink issues across Docker overlay layers |
| `UV_SYSTEM_PYTHON=1` | Use the image's Python directly, don't create a venv |
| `--no-install-project` on deps layer | Install deps without the project package — project arrives with `COPY backend/` |
| `--no-dev` | Runtime image excludes `[tool.uv.dev-dependencies]` |
| `useradd --uid 1000` | Matches default host UID on macOS/Linux, avoids volume perm issues |

## Why Two Install Steps

If you `COPY . .` before `uv sync`, every code edit invalidates the dep install layer and rebuilds from scratch. Splitting the copy into **lockfile first, code second** means the 30-second `uv sync` only runs when `uv.lock` actually changed.

## Dev vs Prod Image Paths

The prototype uses one image for both `backend` and `indexer` because they share dependencies. For Lambda production, the Dockerfile changes:

- `FROM public.ecr.aws/lambda/python:3.12`
- `CMD ["app.lambda_handler.handler"]`
- No Uvicorn; Mangum is the adapter

Keeping the local Dockerfile minimal and separate from the Lambda Dockerfile is PC-003 in practice: no Mangum in the local image, no Uvicorn in the Lambda image.

## Example Usage

```bash
docker compose build backend              # rebuild image
docker compose build --no-cache backend   # force full rebuild

# Inspect layer sizes
docker history devops-wiki-backend
```

## See Also

- [three-service-compose](three-service-compose.md)
- [../concepts/volumes-and-uids](../concepts/volumes-and-uids.md)
- [../concepts/secrets-hygiene](../concepts/secrets-hygiene.md)
