import type { AgentCard } from './types';

const memo = new Map<string, AgentCard>();

export async function fetchAgentCard(plannerUrl: string): Promise<AgentCard> {
  const cached = memo.get(plannerUrl);
  if (cached) return cached;

  try {
    const res = await fetch(`${plannerUrl}/.well-known/agent.json`, {
      next: { revalidate: 300 },
    });
    if (!res.ok) {
      throw new Error(`AgentCard fetch failed: ${res.status}`);
    }
    const card = (await res.json()) as AgentCard;
    memo.set(plannerUrl, card);
    return card;
  } catch {
    const fallback: AgentCard = {
      name: 'Dataset Whisperer',
      description: 'Conversational data analysis agent',
    };
    return fallback;
  }
}
