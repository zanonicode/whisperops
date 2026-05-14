import { NextResponse } from 'next/server';
import { fetchAgentCard } from '@/lib/kagent/agentCard';

export const dynamic = 'force-dynamic';
export const revalidate = 300;

export async function GET() {
  const plannerUrl = process.env.PLANNER_URL;
  if (!plannerUrl) {
    return NextResponse.json(
      { error: 'PLANNER_URL not configured' },
      { status: 503 }
    );
  }

  try {
    const card = await fetchAgentCard(plannerUrl);
    return NextResponse.json(card);
  } catch (err) {
    const message = err instanceof Error ? err.message : 'AgentCard fetch failed';
    return NextResponse.json({ error: message }, { status: 502 });
  }
}
