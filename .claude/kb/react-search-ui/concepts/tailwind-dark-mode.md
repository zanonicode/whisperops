# Tailwind Dark Mode (`class` Strategy)

> **Purpose**: Dark-mode styling driven by a toggle the user controls
> **Confidence**: HIGH
> **MCP Validated**: 2026-04-23

## `class` vs `media`

Tailwind offers two dark-mode strategies:

| Strategy | Trigger | User Override |
|----------|---------|---------------|
| `media` | OS preference (`prefers-color-scheme`) | Impossible |
| **`class`** | `<html class="dark">` present | **Yes — JS toggles the class** |

For this project we need a **user-facing toggle**, so `class` is the only
viable choice. System preference is still respected on first load, but the
user can override it.

## Config

```js
// tailwind.config.js
export default {
  darkMode: 'class',
  content: ['./index.html', './src/**/*.{ts,tsx}'],
};
```

## Using `dark:` Variants

```tsx
<div className="bg-white text-slate-900 dark:bg-slate-900 dark:text-slate-100">
  Hello
</div>
```

When `<html class="dark">` is set, the `dark:` utilities win. Otherwise the
base utilities apply.

## The Three Rules of a Good Toggle

1. **Default to system preference** on first visit
   (`window.matchMedia('(prefers-color-scheme: dark)')`).
2. **Persist the user's choice** in `localStorage` once they toggle.
3. **Apply before first paint** — otherwise light mode flashes on reload.

## Pre-Paint Script (FOUC Prevention)

Inlined in `index.html` `<head>` — runs synchronously before React mounts:

```html
<script>
  (function () {
    const stored = localStorage.getItem('theme');
    const systemDark = window.matchMedia('(prefers-color-scheme: dark)').matches;
    const dark = stored ? stored === 'dark' : systemDark;
    if (dark) document.documentElement.classList.add('dark');
  })();
</script>
```

Without this, users see a white flash on every reload in dark mode.

## `useDarkMode` Hook

```ts
import { useEffect, useState } from 'react';

type Theme = 'light' | 'dark';

export function useDarkMode(): [boolean, (v: boolean) => void] {
  const [isDark, setIsDark] = useState<boolean>(
    () => document.documentElement.classList.contains('dark')
  );

  useEffect(() => {
    document.documentElement.classList.toggle('dark', isDark);
    localStorage.setItem('theme', isDark ? 'dark' : 'light');
  }, [isDark]);

  return [isDark, setIsDark];
}
```

## Toggle Button

```tsx
function DarkModeToggle() {
  const [isDark, setIsDark] = useDarkMode();
  return (
    <button
      onClick={() => setIsDark(!isDark)}
      aria-label="Toggle dark mode"
      className="rounded p-2 hover:bg-slate-200 dark:hover:bg-slate-700"
    >
      {isDark ? '☀' : '🌙'}
    </button>
  );
}
```

## Respect System Changes (Optional)

If the user has not set an override, follow OS changes live:

```ts
useEffect(() => {
  if (localStorage.getItem('theme')) return;      // user has an override
  const mq = window.matchMedia('(prefers-color-scheme: dark)');
  const onChange = (e: MediaQueryListEvent) => setIsDark(e.matches);
  mq.addEventListener('change', onChange);
  return () => mq.removeEventListener('change', onChange);
}, []);
```

## Common Mistakes

### Wrong — toggling `body` class

Tailwind looks at `<html>` (the `documentElement`), not `<body>`.

### Wrong — `darkMode: 'media'` + user toggle

They're mutually exclusive. `'media'` ignores the `dark` class entirely.

### Wrong — no pre-paint script

A `useEffect` runs after mount → white flash on every reload.

## Related

- [quick-reference.md](../quick-reference.md) — dark-mode color palette
- [patterns/search-page-component.md](../patterns/search-page-component.md) — toggle placement
