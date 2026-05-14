export interface ThreadMessage {
  id: string;
  role: 'user' | 'assistant';
  text: string;
}

export interface Thread {
  id: string;
  contextId?: string;
  title: string;
  createdAt: number;
  updatedAt: number;
  messages: ThreadMessage[];
}

interface Store {
  version: 1;
  activeId: string | null;
  threads: Thread[];
}

const EMPTY: Store = { version: 1, activeId: null, threads: [] };

function key(agent: string): string {
  return `whisperops/threads/v1/${agent}`;
}

export function loadThreads(agent: string): Store {
  if (typeof window === 'undefined') return EMPTY;
  try {
    const raw = localStorage.getItem(key(agent));
    if (!raw) return EMPTY;
    const parsed = JSON.parse(raw) as Store;
    if (parsed.version === 1) return parsed;
    return EMPTY;
  } catch {
    return EMPTY;
  }
}

export function saveThreads(agent: string, store: Store): void {
  if (typeof window === 'undefined') return;
  try {
    localStorage.setItem(key(agent), JSON.stringify(store));
  } catch {
    // Quota exceeded — silently no-op; future enhancement: LRU prune
  }
}

export function createThread(firstMessage: string): Thread {
  const now = Date.now();
  return {
    id: typeof crypto !== 'undefined' ? crypto.randomUUID() : `${now}`,
    title: firstMessage.slice(0, 60),
    createdAt: now,
    updatedAt: now,
    messages: [],
  };
}
