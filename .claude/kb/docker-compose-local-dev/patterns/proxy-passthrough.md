# Corporate VPN / Proxy Pass-Through

> **Purpose:** Let `httpx` inside the `backend` and `indexer` containers reach `platformwiki.o9solutions.com`, `community.o9solutions.com`, and the ADO Git endpoint when the host is on a corporate VPN. Covers R-P3 and QP4.
> **MCP Validated:** 2026-04-24

## When to Use

- You're on a corporate VPN where outbound HTTPS requires `HTTPS_PROXY`
- `docker compose run --rm indexer` fails with TLS timeouts but `curl` from host works
- You want one config knob (`HTTPS_PROXY` env) rather than `network_mode: host`

## Implementation

### Step 1 — Export proxy vars on the host

```bash
# ~/.zshrc or shell init
export HTTPS_PROXY="http://proxy.corp:8080"
export HTTP_PROXY="http://proxy.corp:8080"
export NO_PROXY="localhost,127.0.0.1,.corp"
```

### Step 2 — Forward into compose services (pull-through)

```yaml
# docker-compose.yml excerpt
services:
  backend:
    environment:
      HTTPS_PROXY: ${HTTPS_PROXY:-}
      HTTP_PROXY:  ${HTTP_PROXY:-}
      NO_PROXY:    ${NO_PROXY:-}

  indexer:
    environment:
      HTTPS_PROXY: ${HTTPS_PROXY:-}
      HTTP_PROXY:  ${HTTP_PROXY:-}
      NO_PROXY:    ${NO_PROXY:-}
      GIT_HTTPS_PROXY: ${HTTPS_PROXY:-}    # GitPython honors this
```

The `:-` default means compose uses an empty string if the host env is unset — no error, proxy simply off.

### Step 3 — Verify egress from inside the container

```bash
docker compose run --rm backend \
  python -c "import httpx; print(httpx.get('https://platformwiki.o9solutions.com').status_code)"
# Expect: 200 (or 301/302 — anything but a connect timeout)
```

If it fails, check:

1. `env | grep PROXY` inside the container shows your values
2. `curl -vI https://platformwiki.o9solutions.com` from the container resolves the host
3. Proxy is reachable from inside Docker's bridge network (some corporate proxies bind to host-only interfaces)

## Why Not `network_mode: host`?

It's tempting — containers share the host network stack and inherit VPN routes. But:

- Breaks on Docker Desktop for Mac (no real host networking)
- Unpublishes Compose DNS (`frontend` → `backend` stops working by name)
- Loses port isolation — a dev-mode server suddenly binds `:80`

Use proxy env pass-through instead. It's the same knob production needs (Lambda VPC + egress NAT is the cloud equivalent).

## Git-Specific Proxy

`GitPython` (the indexer's clone driver) respects the `HTTPS_PROXY` env AND `http.proxy` git config. The env path is enough for the prototype:

```python
# indexer/app/index_build.py
import os
from git import Repo

proxy = os.environ.get("HTTPS_PROXY")
# No extra config needed — GitPython shells out to git, git honors env.
Repo.clone_from(url, "/clone", env={"HTTPS_PROXY": proxy} if proxy else None)
```

## Common Pitfalls

| Symptom | Cause | Fix |
|---------|-------|-----|
| `ssl: CERTIFICATE_VERIFY_FAILED` | Corporate MITM proxy | Mount corporate CA cert: `-v /path/to/ca.crt:/etc/ssl/certs/corp-ca.crt:ro` and set `REQUESTS_CA_BUNDLE`/`SSL_CERT_FILE` |
| Connect timeout only on container | Proxy bound to `127.0.0.1` on host | Use `http://host.docker.internal:<port>` as proxy URL (Docker Desktop only) |
| Works for `httpx`, fails for `git clone` | `git` ignoring env | Add `-c http.proxy=$HTTPS_PROXY` to git command, or `git config --global http.proxy` at container start |

## Example Usage

```bash
# Host-side (~/.zshrc)
export HTTPS_PROXY=http://proxy.corp:8080

# Compose picks it up automatically via ${HTTPS_PROXY:-}
docker compose up backend

# Spike S2 probe
docker compose run --rm backend \
  python -c "import httpx; r=httpx.get('https://platformwiki.o9solutions.com/api.php?action=query&list=search&srsearch=test&format=json'); print(r.status_code, r.text[:200])"
```

## See Also

- [three-service-compose](three-service-compose.md)
- [../concepts/compose-services](../concepts/compose-services.md)
- [../../azure-devops-wiki/index.md](../../azure-devops-wiki/index.md)
