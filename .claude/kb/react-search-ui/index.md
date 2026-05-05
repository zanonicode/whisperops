# React Search UI Knowledge Base

> **MCP Validated:** 2026-04-23

## Purpose

Build patterns for the DevOps Wiki search SPA: a single page with a search box
and an infinite-scroll list of results badged by source (ADO / MediaWiki /
Discourse). React 18 + TypeScript (strict) + Vite + Tailwind CSS.

## Scope

**In scope:**
- Debounced search-as-you-type + AbortController for superseded fetches
- Infinite scroll via `IntersectionObserver` + sentinel element
- Dark mode via Tailwind `class` strategy (system preference + user override)
- Typed API client mirroring backend Pydantic shapes
- Result-item rendering with source badge + backend-supplied HTML snippet

**Out of scope (owned elsewhere):**
- Authentication / MSAL.js / token acquisition → see sibling `microsoft-sso` KB
- Backend snippet generation → see sibling `sqlite-fts5` KB
- External source protocols → `mediawiki-api`, `discourse-api`,
  `azure-devops-wiki` KBs

## Stack

| Layer | Choice |
|-------|--------|
| Framework | React 18 (functional components + hooks) |
| Language | TypeScript, `strict: true` |
| Bundler | Vite |
| Styling | Tailwind CSS, `dark:` class strategy |
| Sanitizer | DOMPurify (for backend snippet HTML) |
| Testing | Vitest + React Testing Library |

## Navigation

### Concepts (how/why)

| File | Topic |
|------|-------|
| [concepts/debounced-search.md](concepts/debounced-search.md) | `useDebounce` + AbortController for superseded requests |
| [concepts/infinite-scroll-intersection-observer.md](concepts/infinite-scroll-intersection-observer.md) | Sentinel-element pattern, cursor pagination |
| [concepts/tailwind-dark-mode.md](concepts/tailwind-dark-mode.md) | `class` strategy, system detect, localStorage persistence |

### Patterns (copy-paste code)

| File | Topic |
|------|-------|
| [patterns/search-page-component.md](patterns/search-page-component.md) | Full `SearchPage.tsx` with all UI states |
| [patterns/result-item-with-snippet.md](patterns/result-item-with-snippet.md) | Badged result row + safe HTML snippet rendering |
| [patterns/api-client-typed.md](patterns/api-client-typed.md) | Typed fetch wrapper mirroring backend Pydantic |

### Quick Reference

| File | Purpose |
|------|---------|
| [quick-reference.md](quick-reference.md) | Hooks, Tailwind snippets, API shapes |

## Conventions

- **One language per layer** — no Python in frontend
- **TS types hand-mirror backend Pydantic** (`SearchHit`, `SearchResponse`)
- **No CSS-in-JS** — Tailwind utilities only
- **Functional components + hooks** — no class components
- **File naming:** `PascalCase.tsx` for components, `camelCase.ts` for hooks/utils

## Related KBs

| KB | Why |
|----|-----|
| `microsoft-sso` | Wraps `SearchPage` with MSAL provider; attaches bearer token |
| `sqlite-fts5` | Produces the HTML snippets this UI renders |
| `fastapi-lambda` | Defines the `/search` endpoint contract consumed here |
