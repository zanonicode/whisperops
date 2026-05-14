import { describe, it, expect } from 'vitest';
import { buildStreamEnvelope, buildSendEnvelope } from '@/lib/kagent/envelope';

describe('buildStreamEnvelope', () => {
  it('produces a valid JSONRPC 2.0 message/stream envelope', () => {
    const env = buildStreamEnvelope('hello', undefined, 'msg-1');
    expect(env.jsonrpc).toBe('2.0');
    expect(env.method).toBe('message/stream');
    const params = env.params as Record<string, unknown>;
    const message = params.message as Record<string, unknown>;
    expect(message.role).toBe('user');
    expect(message.messageId).toBe('msg-1');
    const parts = message.parts as Array<{ kind: string; text: string }>;
    expect(parts[0].text).toBe('hello');
  });

  it('includes contextId when provided', () => {
    const env = buildStreamEnvelope('hi', 'ctx-42', 'msg-2');
    const params = env.params as Record<string, unknown>;
    expect(params.contextId).toBe('ctx-42');
  });

  it('omits contextId when undefined', () => {
    const env = buildStreamEnvelope('hi', undefined, 'msg-3');
    const params = env.params as Record<string, unknown>;
    expect('contextId' in params).toBe(false);
  });
});

describe('buildSendEnvelope', () => {
  it('produces a valid JSONRPC 2.0 message/send envelope', () => {
    const env = buildSendEnvelope('hello', undefined, 'msg-4');
    expect(env.method).toBe('message/send');
  });

  it('includes contextId when provided', () => {
    const env = buildSendEnvelope('hi', 'ctx-99', 'msg-5');
    const params = env.params as Record<string, unknown>;
    expect(params.contextId).toBe('ctx-99');
  });
});
