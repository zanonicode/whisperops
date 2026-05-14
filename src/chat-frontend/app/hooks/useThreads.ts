'use client';

import { useCallback, useEffect, useRef, useState } from 'react';
import {
  loadThreads,
  saveThreads,
  createThread,
  type Thread,
  type ThreadMessage,
} from '@/lib/threads';

interface UseThreadsReturn {
  threads: Thread[];
  activeThread: Thread | null;
  activeThreadId: string | null;
  addThread: (firstMessage: string) => Thread;
  switchThread: (id: string) => void;
  deleteThread: (id: string) => void;
  updateThread: (id: string, updates: Partial<Thread>) => void;
  appendMessage: (threadId: string, message: ThreadMessage) => void;
  setContextId: (threadId: string, contextId: string) => void;
}

export function useThreads(agentName: string): UseThreadsReturn {
  const [threads, setThreads] = useState<Thread[]>([]);
  const [activeThreadId, setActiveThreadId] = useState<string | null>(null);
  const initialized = useRef(false);

  useEffect(() => {
    if (initialized.current) return;
    initialized.current = true;
    const store = loadThreads(agentName);
    setThreads(store.threads);
    setActiveThreadId(store.activeId);
  }, [agentName]);

  const persist = useCallback(
    (newThreads: Thread[], newActiveId: string | null) => {
      saveThreads(agentName, { version: 1, activeId: newActiveId, threads: newThreads });
    },
    [agentName]
  );

  const addThread = useCallback(
    (firstMessage: string): Thread => {
      const thread = createThread(firstMessage);
      setThreads((prev) => {
        const next = [thread, ...prev];
        persist(next, thread.id);
        return next;
      });
      setActiveThreadId(thread.id);
      return thread;
    },
    [persist]
  );

  const switchThread = useCallback(
    (id: string) => {
      setActiveThreadId(id);
      setThreads((prev) => {
        persist(prev, id);
        return prev;
      });
    },
    [persist]
  );

  const deleteThread = useCallback(
    (id: string) => {
      setThreads((prev) => {
        const next = prev.filter((t) => t.id !== id);
        const newActive = next[0]?.id ?? null;
        setActiveThreadId(newActive);
        persist(next, newActive);
        return next;
      });
    },
    [persist]
  );

  const updateThread = useCallback(
    (id: string, updates: Partial<Thread>) => {
      setThreads((prev) => {
        const next = prev.map((t) =>
          t.id === id ? { ...t, ...updates, updatedAt: Date.now() } : t
        );
        persist(next, activeThreadId);
        return next;
      });
    },
    [persist, activeThreadId]
  );

  const appendMessage = useCallback(
    (threadId: string, message: ThreadMessage) => {
      setThreads((prev) => {
        const next = prev.map((t) =>
          t.id === threadId
            ? { ...t, messages: [...t.messages, message], updatedAt: Date.now() }
            : t
        );
        persist(next, activeThreadId);
        return next;
      });
    },
    [persist, activeThreadId]
  );

  const setContextId = useCallback(
    (threadId: string, contextId: string) => {
      setThreads((prev) => {
        const next = prev.map((t) =>
          t.id === threadId ? { ...t, contextId, updatedAt: Date.now() } : t
        );
        persist(next, activeThreadId);
        return next;
      });
    },
    [persist, activeThreadId]
  );

  const activeThread = threads.find((t) => t.id === activeThreadId) ?? null;

  return {
    threads,
    activeThread,
    activeThreadId,
    addThread,
    switchThread,
    deleteThread,
    updateThread,
    appendMessage,
    setContextId,
  };
}
