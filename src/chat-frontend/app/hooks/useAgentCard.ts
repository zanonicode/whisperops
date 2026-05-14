'use client';

import { useEffect, useState } from 'react';
import type { AgentCard } from '@/lib/kagent/types';

interface UseAgentCardReturn {
  card: AgentCard | null;
  loading: boolean;
  error: string | null;
}

export function useAgentCard(): UseAgentCardReturn {
  const [card, setCard] = useState<AgentCard | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;

    (async () => {
      try {
        const res = await fetch('/api/agent-card');
        if (!res.ok) {
          if (!cancelled) setError(`${res.status} ${res.statusText}`);
          return;
        }
        const data = (await res.json()) as AgentCard;
        if (!cancelled) setCard(data);
      } catch (err) {
        if (!cancelled) setError(err instanceof Error ? err.message : 'fetch failed');
      } finally {
        if (!cancelled) setLoading(false);
      }
    })();

    return () => {
      cancelled = true;
    };
  }, []);

  return { card, loading, error };
}
