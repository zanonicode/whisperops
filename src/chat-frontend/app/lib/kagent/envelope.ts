function buildMessage(text: string, contextId: string | undefined, messageId: string) {
  // kagent v0.9.x honors contextId ONLY when placed INSIDE the message object.
  // Placing it at params.contextId is silently ignored (planner creates a new
  // session instead of resuming). Verified empirically 2026-05-14 against
  // agent-spotify-data planner. See kb/kagent/patterns/message-stream-envelope.md.
  const message: Record<string, unknown> = {
    role: 'user',
    parts: [{ kind: 'text', text }],
    messageId,
  };
  if (contextId) {
    message.contextId = contextId;
  }
  return message;
}

export function buildStreamEnvelope(
  text: string,
  contextId: string | undefined,
  messageId: string,
): Record<string, unknown> {
  return {
    jsonrpc: '2.0',
    id: 1,
    method: 'message/stream',
    params: { message: buildMessage(text, contextId, messageId) },
  };
}

export function buildSendEnvelope(
  text: string,
  contextId: string | undefined,
  messageId: string,
): Record<string, unknown> {
  return {
    jsonrpc: '2.0',
    id: 1,
    method: 'message/send',
    params: { message: buildMessage(text, contextId, messageId) },
  };
}
