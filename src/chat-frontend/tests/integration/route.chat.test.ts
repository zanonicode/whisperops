import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';

vi.mock('@/lib/env', () => ({
  getEnv: () => ({
    PLANNER_URL: 'http://planner.test:8083',
    STREAMING_ENABLED: 'true',
    AGENT_NAME: 'test-agent',
  }),
}));

vi.mock('@/lib/id', () => ({
  newId: () => 'test-msg-id',
}));

vi.mock('@/lib/kagent/relay', () => ({
  createRelay: (_body: unknown, _opts: unknown) => ({
    stream: new ReadableStream({
      start(ctrl) {
        ctrl.enqueue(new TextEncoder().encode('data: {}\n\n'));
        ctrl.close();
      },
    }),
    headers: { 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-cache' },
  }),
}));

import { NextRequest } from 'next/server';

function makeRequest(body: unknown, url = 'http://localhost/api/chat') {
  return new NextRequest(url, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });
}

describe('POST /api/chat', () => {
  beforeEach(() => {
    vi.stubGlobal(
      'fetch',
      vi.fn().mockResolvedValue({
        ok: true,
        status: 200,
        body: new ReadableStream({ start(ctrl) { ctrl.close(); } }),
      })
    );
  });

  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it('returns 400 when text is missing', async () => {
    const { POST } = await import('@/api/chat/route');
    const res = await POST(makeRequest({}));
    expect(res.status).toBe(400);
  });

  it('returns 400 when text is empty', async () => {
    const { POST } = await import('@/api/chat/route');
    const res = await POST(makeRequest({ text: '   ' }));
    expect(res.status).toBe(400);
  });

  it('returns 400 on invalid JSON body', async () => {
    const { POST } = await import('@/api/chat/route');
    const req = new NextRequest('http://localhost/api/chat', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: 'not json',
    });
    const res = await POST(req);
    expect(res.status).toBe(400);
  });

  it('returns SSE stream on valid text', async () => {
    const { POST } = await import('@/api/chat/route');
    const res = await POST(makeRequest({ text: 'hello' }));
    expect(res.status).toBe(200);
    expect(res.headers.get('Content-Type')).toContain('text/event-stream');
  });

  it('returns 502 when upstream fetch fails', async () => {
    vi.stubGlobal('fetch', vi.fn().mockRejectedValue(new Error('ECONNREFUSED')));
    const { POST } = await import('@/api/chat/route');
    const res = await POST(makeRequest({ text: 'hello' }));
    expect(res.status).toBe(502);
  });
});
