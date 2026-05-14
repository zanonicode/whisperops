import { describe, it, expect, beforeEach } from 'vitest';
import { loadThreads, saveThreads, createThread } from '@/lib/threads';

beforeEach(() => {
  localStorage.clear();
});

describe('createThread', () => {
  it('creates a thread with the first 60 chars as title', () => {
    const long = 'a'.repeat(100);
    const t = createThread(long);
    expect(t.title).toHaveLength(60);
    expect(t.messages).toHaveLength(0);
  });

  it('uses the full message if shorter than 60 chars', () => {
    const t = createThread('Short title');
    expect(t.title).toBe('Short title');
  });
});

describe('loadThreads / saveThreads round-trip', () => {
  it('returns empty store when nothing saved', () => {
    const store = loadThreads('test-agent');
    expect(store.threads).toHaveLength(0);
    expect(store.activeId).toBeNull();
    expect(store.version).toBe(1);
  });

  it('round-trips threads through localStorage', () => {
    const thread = createThread('Hello test');
    saveThreads('test-agent', { version: 1, activeId: thread.id, threads: [thread] });
    const loaded = loadThreads('test-agent');
    expect(loaded.threads).toHaveLength(1);
    expect(loaded.threads[0].title).toBe('Hello test');
    expect(loaded.activeId).toBe(thread.id);
  });

  it('returns empty store on invalid JSON', () => {
    localStorage.setItem('whisperops/threads/v1/test-agent', '{bad}');
    const store = loadThreads('test-agent');
    expect(store.threads).toHaveLength(0);
  });

  it('scopes per agent name', () => {
    const t1 = createThread('Agent A thread');
    const t2 = createThread('Agent B thread');
    saveThreads('agent-a', { version: 1, activeId: t1.id, threads: [t1] });
    saveThreads('agent-b', { version: 1, activeId: t2.id, threads: [t2] });
    expect(loadThreads('agent-a').threads[0].title).toBe('Agent A thread');
    expect(loadThreads('agent-b').threads[0].title).toBe('Agent B thread');
  });
});
