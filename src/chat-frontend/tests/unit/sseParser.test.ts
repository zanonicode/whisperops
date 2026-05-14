import { describe, it, expect, vi } from 'vitest';
import { parseSSEChunks, extractTextFromParts } from '@/lib/kagent/sseParser';

function makeStream(chunks: string[]): ReadableStream<Uint8Array> {
  const enc = new TextEncoder();
  return new ReadableStream({
    start(ctrl) {
      for (const c of chunks) ctrl.enqueue(enc.encode(c));
      ctrl.close();
    },
  });
}

describe('extractTextFromParts', () => {
  it('returns empty string for undefined', () => {
    expect(extractTextFromParts(undefined)).toBe('');
  });

  it('joins text parts', () => {
    expect(
      extractTextFromParts([
        { kind: 'text', text: 'Hello' },
        { kind: 'file', text: 'ignored' },
        { kind: 'text', text: ' world' },
      ])
    ).toBe('Hello world');
  });
});

describe('parseSSEChunks', () => {
  it('calls onEvent for status-update', async () => {
    const env = {
      result: { kind: 'status-update', state: 'working', final: false, metadata: {} },
    };
    const stream = makeStream([`data: ${JSON.stringify(env)}\n\n`]);
    const handler = vi.fn();
    await parseSSEChunks(stream, handler);
    expect(handler).toHaveBeenCalledOnce();
    expect(handler.mock.calls[0][0].kind).toBe('status-update');
  });

  it('calls onEvent for artifact-update', async () => {
    const env = {
      result: { kind: 'artifact-update', artifact: { parts: [{ kind: 'text', text: 'hi' }] }, lastChunk: true },
    };
    const stream = makeStream([`data: ${JSON.stringify(env)}\n\n`]);
    const handler = vi.fn();
    await parseSSEChunks(stream, handler);
    expect(handler).toHaveBeenCalledOnce();
    expect(handler.mock.calls[0][0].kind).toBe('artifact-update');
  });

  it('ignores malformed JSON lines', async () => {
    const stream = makeStream(['data: {bad json}\n\n']);
    const handler = vi.fn();
    await parseSSEChunks(stream, handler);
    expect(handler).not.toHaveBeenCalled();
  });

  it('handles chunked delivery across multiple reads', async () => {
    const env = {
      result: { kind: 'status-update', state: 'working', final: false, metadata: {} },
    };
    const raw = `data: ${JSON.stringify(env)}\n\n`;
    const mid = Math.floor(raw.length / 2);
    const stream = makeStream([raw.slice(0, mid), raw.slice(mid)]);
    const handler = vi.fn();
    await parseSSEChunks(stream, handler);
    expect(handler).toHaveBeenCalledOnce();
  });
});
