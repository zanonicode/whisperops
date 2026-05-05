# React Search UI Quick Reference

> Hooks, Tailwind snippets, API shapes. React 18 + TS strict + Tailwind.

## Install

```bash
npm create vite@latest devops-wiki-ui -- --template react-ts
npm i -D tailwindcss postcss autoprefixer && npx tailwindcss init -p
npm i dompurify && npm i -D @types/dompurify
```

## `tailwind.config.js`

```js
export default {
  darkMode: 'class',                          // opt-in via <html class="dark">
  content: ['./index.html', './src/**/*.{ts,tsx}'],
  theme: { extend: {} },
  plugins: [],
}
```

## Hooks Cheat Sheet

| Hook | Signature | Purpose |
|------|-----------|---------|
| `useDebounce(value, ms)` | `<T>(v: T, ms: number) => T` | Debounce keystrokes |
| `useSearch(query)` | `(q: string) => SearchState` | Fetch + abort superseded |
| `useInfiniteScroll(cb)` | `(cb: () => void) => Ref` | Sentinel ref for observer |
| `useDarkMode()` | `() => [bool, (b: bool) => void]` | Toggle + persist |

## API Shapes (mirror backend Pydantic)

```ts
export type SourceId = 'ado' | 'mediawiki' | 'discourse';

export interface SearchHit {
  id: string;
  title: string;
  snippet: string;        // HTML with <mark> tags from FTS5 snippet()
  url: string;
  source: SourceId;
  score: number;
}

export interface SearchResponse {
  hits: SearchHit[];
  cursor: string | null;  // null => end of results
  total: number;
}
```

## Tailwind: Dark-Mode Colors

| Role | Light | Dark |
|------|-------|------|
| Background | `bg-white` | `dark:bg-slate-900` |
| Surface | `bg-slate-50` | `dark:bg-slate-800` |
| Text primary | `text-slate-900` | `dark:text-slate-100` |
| Text muted | `text-slate-600` | `dark:text-slate-400` |
| Border | `border-slate-200` | `dark:border-slate-700` |
| Mark bg | `bg-yellow-200` | `dark:bg-yellow-500/40` |

## Source Badge Classes

```tsx
const BADGE: Record<SourceId, string> = {
  ado:        'bg-blue-100   text-blue-800   dark:bg-blue-900/40   dark:text-blue-200',
  mediawiki:  'bg-green-100  text-green-800  dark:bg-green-900/40  dark:text-green-200',
  discourse:  'bg-purple-100 text-purple-800 dark:bg-purple-900/40 dark:text-purple-200',
};
```

## Common Pitfalls

| Don't | Do |
|-------|-----|
| Use `scroll` event | Use `IntersectionObserver` |
| Trust backend HTML | Sanitize with `DOMPurify.sanitize()` |
| Fire fetch on every keystroke | Debounce 250–350ms + abort prior |
| Tailwind `darkMode: 'media'` | Use `'class'` for user override |
| Store full results in state forever | Reset on new query |

## Related

| Topic | Path |
|-------|------|
| Debounce concept | `concepts/debounced-search.md` |
| Infinite scroll concept | `concepts/infinite-scroll-intersection-observer.md` |
| Full SearchPage | `patterns/search-page-component.md` |
