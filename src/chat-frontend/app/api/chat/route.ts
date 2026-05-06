import type { NextRequest } from 'next/server';

/**
 * Chat route handler — proxies user messages to kagent's session API and
 * streams the agent's response back to the browser as SSE.
 *
 * Configuration (env, set on the Deployment):
 *  - KAGENT_BASE_URL    e.g. http://kagent.kagent-system.svc.cluster.local
 *  - AGENT_NAMESPACE    e.g. agent-housing-demo
 *  - AGENT_NAME         e.g. planner   (the agent this UI is scoped to)
 *  - USER_ID            e.g. demo@whisperops
 *
 * Wire pattern (synchronous /invoke, single SSE event with the full reply):
 *  1) On first request, fetch the agent's `component` from
 *     GET /api/agents/{ns}/{name}. This is the team_config kagent's
 *     /invoke handler requires. Cached process-wide.
 *  2) On each user message:
 *     - If no kagent session is associated with this browser session
 *       (cookie `kagent-session-id`), POST /api/sessions to create one.
 *     - POST /api/sessions/{id}/invoke with {task, team_config}.
 *     - Emit one SSE event `data: {"content": "..."}` then `data: [DONE]`.
 *
 * Streaming via /invoke/stream is a future improvement; the synchronous
 * path is enough to prove the user-facing demo works.
 */

const KAGENT_BASE_URL =
  process.env.KAGENT_BASE_URL ?? 'http://kagent.kagent-system.svc.cluster.local';
const AGENT_NAMESPACE = process.env.AGENT_NAMESPACE ?? 'agent-housing-demo';
const AGENT_NAME = process.env.AGENT_NAME ?? 'planner';
const USER_ID = process.env.USER_ID ?? 'demo@whisperops';
const AGENT_REF = `${AGENT_NAMESPACE}/${AGENT_NAME}`;

// Process-wide cache for the agent's team_config Component.
let cachedTeamConfig: unknown = null;

async function fetchTeamConfig(): Promise<unknown> {
  if (cachedTeamConfig) return cachedTeamConfig;
  const url = `${KAGENT_BASE_URL}/api/agents/${AGENT_NAMESPACE}/${AGENT_NAME}`;
  const res = await fetch(url, { cache: 'no-store' });
  if (!res.ok) {
    throw new Error(`kagent /api/agents fetch failed: HTTP ${res.status}`);
  }
  const body = (await res.json()) as { data?: { component?: unknown } };
  if (!body.data?.component) {
    throw new Error('kagent /api/agents response missing data.component');
  }
  cachedTeamConfig = body.data.component;
  return cachedTeamConfig;
}

async function createSession(): Promise<string> {
  const url = `${KAGENT_BASE_URL}/api/sessions`;
  const res = await fetch(url, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      user_id: USER_ID,
      agent_ref: AGENT_REF,
      name: `chat-${Date.now()}`,
    }),
  });
  if (!res.ok) {
    const text = await res.text();
    throw new Error(`kagent createSession failed: HTTP ${res.status} ${text}`);
  }
  const body = (await res.json()) as { data?: { id?: string } };
  if (!body.data?.id) {
    throw new Error('kagent createSession response missing data.id');
  }
  return body.data.id;
}

interface InvokeMessage {
  type?: string;
  source?: string;
  content?: string;
}

async function invoke(sessionId: string, task: string): Promise<string> {
  const teamConfig = await fetchTeamConfig();
  const url = `${KAGENT_BASE_URL}/api/sessions/${sessionId}/invoke?user_id=${encodeURIComponent(USER_ID)}`;
  const res = await fetch(url, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ task, team_config: teamConfig }),
  });
  if (!res.ok) {
    const text = await res.text();
    throw new Error(`kagent /invoke failed: HTTP ${res.status} ${text}`);
  }
  const body = (await res.json()) as { data?: InvokeMessage[]; error?: string | boolean };
  const err = body.error;
  if (typeof err === 'string') {
    throw new Error(err);
  }
  if (err === true) {
    throw new Error('kagent invoke errored');
  }
  // The data array is [user_message, ...agent_messages]. Pick the last
  // assistant TextMessage with non-empty content as the answer.
  const messages = body.data ?? [];
  for (let i = messages.length - 1; i >= 0; i--) {
    const m = messages[i];
    if (m.type === 'TextMessage' && m.source !== 'user' && m.content) {
      return m.content;
    }
  }
  return '(no assistant response)';
}

function sseChunk(payload: object): Uint8Array {
  return new TextEncoder().encode(`data: ${JSON.stringify(payload)}\n\n`);
}

export async function POST(req: NextRequest): Promise<Response> {
  const reqBody = (await req.json()) as { message?: string };
  const message = (reqBody.message ?? '').trim();
  if (!message) {
    return new Response(JSON.stringify({ error: 'message is required' }), {
      status: 400,
      headers: { 'Content-Type': 'application/json' },
    });
  }

  // Look up or create a kagent session for this browser via cookie.
  const cookieHeader = req.headers.get('cookie') ?? '';
  const cookieMatch = cookieHeader.match(/kagent-session-id=([a-f0-9-]+)/);
  let sessionId = cookieMatch?.[1];
  let setCookie: string | null = null;
  if (!sessionId) {
    sessionId = await createSession();
    setCookie = `kagent-session-id=${sessionId}; Path=/; HttpOnly; SameSite=Lax; Max-Age=86400`;
  }

  const stream = new ReadableStream({
    async start(controller) {
      try {
        const reply = await invoke(sessionId!, message);
        controller.enqueue(sseChunk({ content: reply }));
        controller.enqueue(new TextEncoder().encode('data: [DONE]\n\n'));
      } catch (err) {
        const msg = err instanceof Error ? err.message : 'invoke failed';
        controller.enqueue(sseChunk({ error: msg }));
      } finally {
        controller.close();
      }
    },
  });

  const headers: Record<string, string> = {
    'Content-Type': 'text/event-stream',
    'Cache-Control': 'no-cache, no-transform',
    Connection: 'keep-alive',
    'X-Accel-Buffering': 'no',
  };
  if (setCookie) headers['Set-Cookie'] = setCookie;

  return new Response(stream, { headers });
}
