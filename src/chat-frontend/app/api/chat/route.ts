import type { NextRequest } from 'next/server';
import { SpanStatusCode } from '@opentelemetry/api';
import { getServerTracer } from '../../../lib/server-tracing';
import { fetchInvokeResponse, processInvokeStream, KagentInvokeError } from '../../../lib/kagent-stream';

const KAGENT_BASE_URL =
  process.env.KAGENT_BASE_URL ?? 'http://kagent.kagent-system.svc.cluster.local';
const AGENT_NAMESPACE = process.env.AGENT_NAMESPACE ?? 'agent-housing-demo';
const AGENT_NAME = process.env.AGENT_NAME ?? 'planner';
const USER_ID = process.env.USER_ID ?? 'demo@whisperops';
const AGENT_REF = `${AGENT_NAMESPACE}/${AGENT_NAME}`;

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

function isSessionNotFound(err: unknown): boolean {
  return (
    err instanceof KagentInvokeError &&
    err.status === 404 &&
    /session not found/i.test(err.bodyText)
  );
}

function sessionCookieValue(sessionId: string): string {
  return `kagent-session-id=${sessionId}; Path=/; HttpOnly; SameSite=Lax; Max-Age=86400`;
}

function sseChunk(payload: object): Uint8Array {
  return new TextEncoder().encode(`data: ${JSON.stringify(payload)}\n\n`);
}

export async function POST(req: NextRequest): Promise<Response> {
  const tracer = getServerTracer();
  const span = tracer.startSpan('chat.handle');
  span.setAttribute('agent.id', AGENT_NAMESPACE);
  span.setAttribute('agent.ref', AGENT_REF);

  const reqBody = (await req.json()) as { message?: string };
  const message = (reqBody.message ?? '').trim();
  span.setAttribute('message.length', message.length);
  if (!message) {
    span.setStatus({ code: SpanStatusCode.ERROR, message: 'empty message' });
    span.end();
    return new Response(JSON.stringify({ error: 'message is required' }), {
      status: 400,
      headers: { 'Content-Type': 'application/json' },
    });
  }

  const cookieHeader = req.headers.get('cookie') ?? '';
  const cookieMatch = cookieHeader.match(/kagent-session-id=([a-f0-9-]+)/);
  let sessionId = cookieMatch?.[1];
  let setCookie: string | null = null;
  if (!sessionId) {
    sessionId = await createSession();
    setCookie = sessionCookieValue(sessionId);
  }

  // Fetch the team config and the upstream invoke response before building the
  // ReadableStream so that a recoverable 404 can be handled and the Set-Cookie
  // header can reflect the final session id used.
  let teamConfig: unknown;
  let upstream: Response;
  let recovered = false;

  try {
    teamConfig = await fetchTeamConfig();
    upstream = await fetchInvokeResponse(KAGENT_BASE_URL, sessionId, USER_ID, message, teamConfig);
  } catch (err) {
    if (isSessionNotFound(err)) {
      span.addEvent('session_recovered_after_404');
      sessionId = await createSession();
      setCookie = sessionCookieValue(sessionId);
      recovered = true;
      // Let any second failure propagate as a non-recoverable error.
      upstream = await fetchInvokeResponse(KAGENT_BASE_URL, sessionId, USER_ID, message, teamConfig!);
    } else {
      const msg = err instanceof Error ? err.message : 'invoke failed';
      span.setAttribute('session.recovered', false);
      span.recordException(err instanceof Error ? err : new Error(msg));
      span.setStatus({ code: SpanStatusCode.ERROR, message: msg });
      span.end();
      const errorStream = new ReadableStream({
        start(controller) {
          controller.enqueue(sseChunk({ error: msg }));
          controller.close();
        },
      });
      return new Response(errorStream, {
        headers: {
          'Content-Type': 'text/event-stream',
          'Cache-Control': 'no-cache, no-transform',
          Connection: 'keep-alive',
          'X-Accel-Buffering': 'no',
        },
      });
    }
  }

  span.setAttribute('session.recovered', recovered);

  const capturedUpstream = upstream!;
  const capturedSessionId = sessionId;

  const stream = new ReadableStream({
    async start(controller) {
      const invokeSpan = tracer.startSpan('kagent.invoke');
      invokeSpan.setAttribute('agent.id', AGENT_NAMESPACE);
      invokeSpan.setAttribute('agent.role', AGENT_NAME);
      invokeSpan.setAttribute('agent.ref', AGENT_REF);
      invokeSpan.setAttribute('kagent.session_id', capturedSessionId);
      invokeSpan.setAttribute('user.id', USER_ID);
      invokeSpan.setAttribute('session.recovered', recovered);
      let finalChunkCount = 0;
      try {
        await processInvokeStream(
          capturedUpstream,
          controller,
          (n) => { finalChunkCount = n; },
        );
        invokeSpan.setAttribute('stream.chunk_count', finalChunkCount);
        invokeSpan.setStatus({ code: SpanStatusCode.OK });
        span.setStatus({ code: SpanStatusCode.OK });
      } catch (err) {
        const msg = err instanceof Error ? err.message : 'invoke failed';
        controller.enqueue(sseChunk({ error: msg }));
        invokeSpan.recordException(err instanceof Error ? err : new Error(msg));
        invokeSpan.setStatus({ code: SpanStatusCode.ERROR, message: msg });
        span.recordException(err instanceof Error ? err : new Error(msg));
        span.setStatus({ code: SpanStatusCode.ERROR, message: msg });
      } finally {
        controller.close();
        invokeSpan.end();
        span.end();
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
