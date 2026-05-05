# Hot Reload — Vite HMR + Uvicorn `--reload`

> **Purpose:** Both services reload on source edit without restarts. Covers PNFR-002 and R-P7.
> **MCP Validated:** 2026-04-24

## When to Use

- Daily dev on the prototype — bind mounts + watchers must work through Docker
- Debugging why Vite HMR went silent after moving files onto a bind mount
- Deciding whether to enable polling mode (macOS/Windows sometimes need it)

## Implementation

### Backend — Uvicorn `--reload`

```yaml
# docker-compose.yml excerpt
services:
  backend:
    volumes:
      - ./backend:/app     # bind-mount the code
    command:
      - uvicorn
      - app.main:app
      - --host=0.0.0.0
      - --port=8000
      - --reload
      - --reload-dir=/app
```

Uvicorn watches files natively. On macOS/Windows bind mounts, inotify events sometimes don't bubble through Docker's filesystem translation. If edits aren't picked up:

```yaml
    command:
      - uvicorn
      - app.main:app
      - --host=0.0.0.0
      - --port=8000
      - --reload
      - --reload-delay=1
      - --reload-include=*.py
```

Or install `watchfiles` (used by Uvicorn when present) and set `WATCHFILES_FORCE_POLLING=true`.

### Frontend — Vite HMR

```yaml
services:
  frontend:
    ports:
      - "5173:5173"
    volumes:
      - ./src:/app/src
      - ./index.html:/app/index.html
      - ./vite.config.ts:/app/vite.config.ts
    command: ["npm", "run", "dev", "--", "--host", "0.0.0.0"]
```

```ts
// vite.config.ts
import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

export default defineConfig({
  plugins: [react()],
  server: {
    host: '0.0.0.0',           // listen on all interfaces inside container
    port: 5173,
    strictPort: true,
    hmr: {
      host: 'localhost',       // what the browser sees
      port: 5173,
      protocol: 'ws',
    },
    watch: {
      // macOS/Windows bind-mount fallback
      usePolling: process.env.CHOKIDAR_USEPOLLING === 'true',
      interval: 500,
    },
  },
})
```

## The Two Addresses Problem

Vite serves at `0.0.0.0:5173` inside the container so Docker port-mapping works. But the HMR websocket URL is what the browser connects to — that has to be `localhost:5173`. Getting this wrong = a silent 1015 websocket close and no HMR.

| Setting | Value | Who sees it |
|---------|-------|-------------|
| `server.host` | `0.0.0.0` | Vite binding inside container |
| `hmr.host` | `localhost` | Browser connecting from host |
| `ports:` in compose | `5173:5173` | Maps host port to container |

## What NOT to Bind-Mount

| Path | Why not |
|------|---------|
| `./node_modules` | Rebuilt with different native bindings on Linux; don't overwrite the image's copy |
| `./.vite` cache | Clashes across host/container Node versions |
| `./__pycache__` | Python version/arch-specific; bind-mounting corrupts |

Fix in `.dockerignore` + selective bind mounts in compose (mount `./src` not `./`).

## Example Usage

```bash
# First-time
docker compose up

# In another terminal, edit src/App.tsx — Vite should HMR within ~100ms
# Edit backend/app/main.py — Uvicorn reloads within ~1s

# If macOS/Windows HMR stops working:
CHOKIDAR_USEPOLLING=true docker compose up
WATCHFILES_FORCE_POLLING=true docker compose up
```

## See Also

- [three-service-compose](three-service-compose.md)
- [../concepts/compose-services](../concepts/compose-services.md)
- [../../react-search-ui/concepts/vite-docker-hmr.md](../../react-search-ui/concepts/vite-docker-hmr.md) *(sibling KB reference — expanded there)*
