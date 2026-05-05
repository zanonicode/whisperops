# Vite Dev Server Inside Docker — HMR That Works

> **Purpose:** Hot-module reload survives running Vite inside `node:20-alpine` with a bind-mounted `./src`. Covers PNFR-002 and R-P7 from the prototype plan.
> **Confidence:** 0.9
> **MCP Validated:** 2026-04-24

## Overview

Vite's dev server is three things: an HTTP server (serves the SPA shell), a websocket (sends HMR updates to the browser), and a file watcher (notices edits). Each crosses a Docker boundary differently. Getting any one wrong = silent HMR failure.

## The Three Boundaries

```text
  Host (your editor)            Container                   Browser
  ─────────────────            ──────────                   ───────
  ./src  edit  ──────►  bind mount  ──────►  file watcher
                                                 │
                                                 ▼
                                          Vite compiles
                                                 │
                                                 ▼
                                           ws :5173  ◄──────────  ws connection
                                                                   from localhost:5173
                                           http :5173  ◄─────────  initial GET
```

## Vite Config (Docker-Aware)

```ts
// vite.config.ts
import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

export default defineConfig({
  plugins: [react()],
  server: {
    host: '0.0.0.0',          // bind all interfaces so Docker port-forward works
    port: 5173,
    strictPort: true,
    hmr: {
      host: 'localhost',      // what the BROWSER connects to
      port: 5173,
      protocol: 'ws',
    },
    watch: {
      usePolling: process.env.CHOKIDAR_USEPOLLING === 'true',
      interval: 500,
    },
  },
})
```

Two hosts, one port. That's the trick: Vite binds to `0.0.0.0` inside the container, but the HMR websocket URL must be `localhost` — because that's the address the browser dials.

## Bind Mount Strategy

```yaml
# docker-compose.yml excerpt
frontend:
  volumes:
    - ./src:/app/src
    - ./index.html:/app/index.html
    - ./vite.config.ts:/app/vite.config.ts
    - ./package.json:/app/package.json
    - ./tsconfig.json:/app/tsconfig.json
    # Do NOT mount ./node_modules — let the image's copy win
```

Mount *what you edit*, not the whole project. Mounting `./` over `/app` shadows the container's `node_modules`, which was installed for Linux but overlaid with whatever the host has (often nothing, sometimes macOS binaries). Symptoms: `esbuild: Error: The package … could not be found` or mysterious missing plugins.

## macOS / Windows HMR Fallback

Native inotify events don't always propagate through Docker's filesystem shim on Desktop. Symptoms:

- Initial page loads fine
- Edit a file — no browser update
- `docker compose logs frontend` is silent

Fix by flipping to polling:

```yaml
frontend:
  environment:
    CHOKIDAR_USEPOLLING: "true"
```

Poll interval = 500ms is a good prototype default. Lower uses more CPU; higher feels laggy.

## Diagnostics

| Symptom | Likely cause | Check |
|---------|--------------|-------|
| "failed to connect to websocket" in DevTools | `hmr.host` wrong | Set `hmr.host: 'localhost'` |
| Page loads but never HMRs | Watcher fired but client disconnected | Check WS in Network tab; expect 101 Switching Protocols |
| `EADDRINUSE 5173` | Port re-used from previous `docker compose` | `docker compose down` first |
| TypeScript edits work, `.tsx` don't | Editor saving to a different path due to symlinks | Stop using symlinks under `./src` |
| Hot reload works for 30s then stops | File watch limits hit | `sysctl fs.inotify.max_user_watches=524288` on Linux host |

## Environment Injection

Vite exposes `import.meta.env.VITE_*` to client code. Compose env vars must have the `VITE_` prefix to pass through:

```yaml
frontend:
  environment:
    VITE_API_BASE:        "http://localhost:8000"
    VITE_ENTRA_TENANT_ID: ${ENTRA_TENANT_ID}
    VITE_ENTRA_CLIENT_ID: ${ENTRA_CLIENT_ID}
```

```ts
const apiBase = import.meta.env.VITE_API_BASE
```

Changes to `VITE_*` env require a Vite restart — they're read at dev-server boot, not per-request.

## Common Mistakes

### Wrong

```ts
// vite.config.ts
server: { host: 'localhost' }     // binds only to loopback; Docker port-forward sees nothing
```

### Correct

```ts
server: { host: '0.0.0.0', hmr: { host: 'localhost' } }
```

## Related

- [infinite-scroll](infinite-scroll.md)
- [dark-mode](dark-mode.md)
- [../../docker-compose-local-dev/patterns/hot-reload-setup.md](../../docker-compose-local-dev/patterns/hot-reload-setup.md)
