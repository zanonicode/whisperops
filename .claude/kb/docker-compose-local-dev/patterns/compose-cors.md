# CORS Between Frontend and Backend Containers

> **Purpose:** FastAPI backend on `:8000` accepts cross-origin requests from the SPA on `:5173` — cleanly, no wildcards, driven by `CORS_ALLOW_ORIGIN` env. Covers PC-004 and R-P2.
> **MCP Validated:** 2026-04-24

## When to Use

- Any time the browser origin (`localhost:5173`) differs from the API origin (`localhost:8000`)
- Before the first `/search` fetch from the SPA — without this, the browser silently drops the response
- When you want the same CORS code path to work locally AND in production (where CloudFront proxies the API GW; origin header may still matter)

## Implementation

### FastAPI wiring

```python
# backend/app/main.py
import os
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

app = FastAPI(title="DevOps Wiki Search")

_allowed = [o.strip() for o in os.environ.get("CORS_ALLOW_ORIGIN", "").split(",") if o.strip()]

app.add_middleware(
    CORSMiddleware,
    allow_origins=_allowed,
    allow_credentials=True,            # SPA sends Bearer token; not cookies, but some SSO flows want this
    allow_methods=["GET", "OPTIONS"],  # prototype only needs GET /search + preflight
    allow_headers=["authorization", "content-type", "x-request-id"],
    max_age=600,                       # cache preflights 10 min
)
```

### Compose wiring

```yaml
services:
  backend:
    environment:
      CORS_ALLOW_ORIGIN: ${CORS_ALLOW_ORIGIN}   # from .env: http://localhost:5173
```

### Verify with curl

```bash
# Preflight
curl -i -X OPTIONS http://localhost:8000/search \
  -H "Origin: http://localhost:5173" \
  -H "Access-Control-Request-Method: GET" \
  -H "Access-Control-Request-Headers: authorization"

# Expect:
# HTTP/1.1 200 OK
# access-control-allow-origin: http://localhost:5173
# access-control-allow-methods: GET, OPTIONS
# access-control-allow-headers: authorization, content-type, x-request-id
# access-control-max-age: 600
```

## Configuration

| Setting | Prototype value | Why |
|---------|-----------------|-----|
| `allow_origins` | `["http://localhost:5173"]` | Exact match. Never `*` — it's incompatible with `allow_credentials=True` |
| `allow_credentials` | `True` | Preserves the pattern production will need; safe because origin is pinned |
| `allow_methods` | `["GET", "OPTIONS"]` | Only what `/search` uses; widen deliberately |
| `allow_headers` | explicit list | Don't echo every header back — that's what `*` does and it hides bugs |
| `max_age` | 600 | Browser caches preflight for 10 min; reduces noise during dev |

## Why Not `allow_origins=["*"]` Even Locally

Three reasons it's a bad default:

1. **Incompatible with credentials.** `*` + `allow_credentials=True` is a spec violation; browsers reject the response.
2. **Drift risk.** A dev-only wildcard has a way of surviving into production configs.
3. **Weakens testing.** Real preflight failures are the signal you want; `*` hides them.

If `ALLOWED_ORIGINS` needs multiple values, comma-separate in `.env`:

```
CORS_ALLOW_ORIGIN=http://localhost:5173,http://127.0.0.1:5173
```

The code already splits on comma.

## What CORS Won't Fix

| Symptom | Actual cause | Fix |
|---------|--------------|-----|
| `net::ERR_CONNECTION_REFUSED` | Backend not listening on `0.0.0.0` | `--host 0.0.0.0` in Uvicorn command |
| `401 Unauthorized` on `/search` | Missing/bad Bearer token | SSO flow; not a CORS issue |
| `TypeError: NetworkError when attempting to fetch` | Usually CORS, sometimes DNS | Check preflight response first |
| Request works in curl, fails in browser | CORS preflight fails | Check `Access-Control-Allow-Origin` echoed back |

## Example Usage

```typescript
// frontend/src/api/search.ts
export async function search(q: string, token: string) {
  const res = await fetch(
    `${import.meta.env.VITE_API_BASE}/search?q=${encodeURIComponent(q)}`,
    { headers: { Authorization: `Bearer ${token}` } }
  )
  if (!res.ok) throw new Error(`search failed: ${res.status}`)
  return res.json()
}
```

## See Also

- [three-service-compose](three-service-compose.md)
- [../concepts/compose-services](../concepts/compose-services.md)
- [../../microsoft-sso/patterns/fastapi-token-validation.md](../../microsoft-sso/patterns/fastapi-token-validation.md)
