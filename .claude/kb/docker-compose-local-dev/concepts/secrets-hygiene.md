# Secrets Hygiene — `.env`, `.dockerignore`, and Image Layers

> **Purpose:** Keep secrets (ADO PAT, client IDs, optional Discourse key) out of the repo, out of image layers, and out of `docker inspect` / `docker history` output. Covers PC-005, PNFR-005, and R-P4.
> **Confidence:** 0.95
> **MCP Validated:** 2026-04-24

## Overview

Three places a secret can leak: the git repo, an image layer, and a running container's environment dump. Each has a distinct mitigation. The prototype uses `.env` + compose `environment:` injection — secrets live only in the running process's env, never in a layer, never in git.

## The Three Leak Paths

| Leak path | Happens when | Mitigation |
|-----------|--------------|------------|
| Git repo | Someone commits `.env` | `.gitignore`, pre-commit hook |
| Image layer | `ENV ADO_PAT=...` or `COPY .env .` in Dockerfile | Use runtime env, not build-time |
| `docker inspect` / `env`-dump | Legitimate at runtime — but avoid logging | Structured logging filters; never `print(os.environ)` |

## The `.env` Contract

```
# .env.example — committed (no secrets)
ENTRA_TENANT_ID=00000000-0000-0000-0000-000000000000
ENTRA_CLIENT_ID=00000000-0000-0000-0000-000000000000
ENTRA_API_AUDIENCE=api://devops-wiki-local
ADO_PAT=                                   # fill locally
ADO_WIKI_REPO_URL=https://o9git.visualstudio.com/.../DevOps-Wiki
PLATFORM_WIKI_BASE=https://platformwiki.o9solutions.com
DISCOURSE_BASE=https://community.o9solutions.com
DISCOURSE_API_KEY=
CORS_ALLOW_ORIGIN=http://localhost:5173
FTS5_DB_PATH=/data/wiki.db
```

```
# .env — NOT committed (real values)
```

Compose loads `.env` automatically and makes keys available for variable substitution in `docker-compose.yml`:

```yaml
services:
  backend:
    environment:
      CORS_ALLOW_ORIGIN: ${CORS_ALLOW_ORIGIN}
      ENTRA_TENANT_ID:   ${ENTRA_TENANT_ID}
      # ...
```

## Required `.gitignore` Lines

```
.env
.env.*
!.env.example
```

## Required `.dockerignore` Lines

```
.env
.env.*
!.env.example
.git
.gitignore
**/__pycache__
**/*.pyc
node_modules
.vite
```

Without `.dockerignore`, `COPY . .` inside the Dockerfile can pull `.env` or the host `.git` directory into the image — permanent, pullable by anyone with registry access.

## Build-time vs Runtime Secrets

| Need | Use |
|------|-----|
| PAT to clone ADO wiki at **runtime** (indexer) | Compose `environment:` + `.env` |
| PAT to install private pip packages at **build time** | `RUN --mount=type=secret,id=pat …` (BuildKit) — **do NOT** `ENV PAT=…` |
| Entra CLIENT_ID in the SPA | Injected at build time via Vite `import.meta.env.VITE_…` — CLIENT_ID is not secret, but same mechanism |

The prototype has zero build-time secrets. Every secret is runtime-only.

## Don't Log What You Load

```python
# NEVER
import os; print(os.environ)
logger.info("config", extra=dict(os.environ))

# SAFE
logger.info("config_loaded", keys=sorted(os.environ.keys()))
```

AWS Lambda Powertools `logger` has `log_uncaught_exceptions=True` by default — good — but you still control what you pass in.

## Rotation Discipline

PATs are rotatable. Treat every prototype PAT as throwaway: short TTL (30–90 days), read-only scope (`vso.wiki`), documented in the team password manager with the developer's name.

## Common Mistakes

### Wrong

```dockerfile
ENV ADO_PAT=abc123...           # bakes into layer; `docker history` reveals it
COPY .env .                     # ships .env into image
```

### Correct

```dockerfile
# No ENV for secrets. Never COPY .env.
# Compose injects at runtime:
# environment:
#   ADO_PAT: ${ADO_PAT}
```

## Related

- [compose-services](compose-services.md)
- [patterns/three-service-compose](../patterns/three-service-compose.md)
- [patterns/uv-dockerfile](../patterns/uv-dockerfile.md)
