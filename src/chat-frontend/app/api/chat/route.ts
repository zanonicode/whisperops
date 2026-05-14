import { NextRequest } from 'next/server';
import { buildStreamEnvelope, buildSendEnvelope } from '@/lib/kagent/envelope';
import { createRelay } from '@/lib/kagent/relay';
import { runSendFallback } from '@/lib/kagent/sendFallback';
import { newId } from '@/lib/id';
import { getEnv } from '@/lib/env';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

export async function POST(req: NextRequest) {
  const env = getEnv();

  let body: { text?: string; contextId?: string };
  try {
    body = (await req.json()) as { text?: string; contextId?: string };
  } catch {
    return Response.json({ error: 'invalid JSON body' }, { status: 400 });
  }

  const { text, contextId } = body;

  if (!text || typeof text !== 'string' || !text.trim()) {
    return Response.json({ error: 'text is required' }, { status: 400 });
  }

  const messageId = newId();

  if (env.STREAMING_ENABLED === 'false') {
    return runSendFallback({
      plannerUrl: env.PLANNER_URL,
      envelope: buildSendEnvelope(text.trim(), contextId, messageId),
    });
  }

  const envelope = buildStreamEnvelope(text.trim(), contextId, messageId);

  let upstream: Response;
  try {
    upstream = await fetch(`${env.PLANNER_URL}/`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Accept: 'text/event-stream',
      },
      body: JSON.stringify(envelope),
      signal: req.signal,
    });
  } catch (err) {
    const message = err instanceof Error ? err.message : 'planner unreachable';
    return Response.json({ error: message }, { status: 502 });
  }

  if (!upstream.ok || !upstream.body) {
    return Response.json(
      { error: `planner returned ${upstream.status}` },
      { status: 502 }
    );
  }

  const { stream, headers } = createRelay(upstream.body, { messageId });
  return new Response(stream, { headers });
}
