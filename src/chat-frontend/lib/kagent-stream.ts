// kagent /invoke/stream SSE event types:
//   frame format: "event: <type>\ndata: <json>\n\n"
//   event: event       — agent messages (see type field inside data JSON)
//   event: task_result — stream-complete marker; data contains full task_result
//
// Forwarding strategy for chat-frontend SSE protocol:
//   ModelClientStreamingChunkEvent  -> data: {"content": "..."} (streaming tokens)
//   TextMessage (source != user)    -> skip (duplicates streaming chunks already delivered)
//   ToolCallRequestEvent            -> skip (planner-internal delegation)
//   ToolCallExecutionEvent          -> skip (sub-agent result; verbose for browser)
//   ToolCallSummaryMessage          -> skip (formatted wrapper of ToolCallExecution)
//   LLMCallEventMessage             -> skip (raw LLM tracing noise)
//   unknown / ThoughtEvent          -> skip
//   task_result event               -> data: [DONE]
//
// invokeStream is split into fetchInvokeResponse + processInvokeStream so route.ts
// can inspect the HTTP status before building the Response, enabling session-lifecycle
// recovery when kagent returns 404 "Session not found".

import { Agent, fetch as undiciFetch } from 'undici';

// Match the kagent ui nginx proxy_read_timeout (600s); undici defaults to 300s.
const longRunningDispatcher = new Agent({
  bodyTimeout: 600_000,
  headersTimeout: 600_000,
});

interface KagentEvent {
  type?: string;
  source?: string;
  content?: unknown;
}

export class KagentInvokeError extends Error {
  readonly status: number;
  readonly bodyText: string;

  constructor(status: number, bodyText: string) {
    super(`kagent /invoke/stream failed: HTTP ${status} ${bodyText}`);
    this.name = 'KagentInvokeError';
    this.status = status;
    this.bodyText = bodyText;
  }
}

function sseBytes(payload: object): Uint8Array {
  return new TextEncoder().encode(`data: ${JSON.stringify(payload)}\n\n`);
}

const DONE_BYTES = new TextEncoder().encode('data: [DONE]\n\n');

export async function fetchInvokeResponse(
  kagentBaseUrl: string,
  sessionId: string,
  userId: string,
  task: string,
  teamConfig: unknown,
): Promise<Response> {
  const url = `${kagentBaseUrl}/api/sessions/${sessionId}/invoke/stream?user_id=${encodeURIComponent(userId)}`;
  const upstream = await undiciFetch(url, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Accept: 'text/event-stream' },
    body: JSON.stringify({ task, team_config: teamConfig }),
    dispatcher: longRunningDispatcher,
  });
  if (!upstream.ok || !upstream.body) {
    const text = await upstream.text().catch(() => '');
    throw new KagentInvokeError(upstream.status, text);
  }
  return upstream as unknown as Response;
}

export async function processInvokeStream(
  upstream: Response,
  controller: ReadableStreamDefaultController,
  onChunkCount: (n: number) => void,
): Promise<void> {
  if (!upstream.body) {
    throw new KagentInvokeError(upstream.status, 'no response body');
  }

  const reader = upstream.body.getReader();
  const decoder = new TextDecoder();
  let buffer = '';
  let chunkCount = 0;
  let contentChunks = 0;

  while (true) {
    const { done, value } = await reader.read();
    if (done) break;

    buffer += decoder.decode(value, { stream: true });
    const lines = buffer.split('\n');
    buffer = lines.pop() ?? '';

    let currentEventType = '';
    for (const line of lines) {
      if (line.startsWith('event: ')) {
        currentEventType = line.slice(7).trim();
        continue;
      }
      if (!line.startsWith('data: ')) continue;

      chunkCount++;
      onChunkCount(chunkCount);

      if (currentEventType === 'task_result') {
        controller.enqueue(
          contentChunks === 0
            ? sseBytes({ error: 'agent produced no response' })
            : DONE_BYTES,
        );
        return;
      }

      const raw = line.slice(6);
      let evt: KagentEvent;
      try {
        evt = JSON.parse(raw) as KagentEvent;
      } catch {
        continue;
      }

      if (evt.type === 'ModelClientStreamingChunkEvent') {
        const text = typeof evt.content === 'string' ? evt.content : null;
        if (text) {
          controller.enqueue(sseBytes({ content: text }));
          contentChunks++;
        }
      }
    }
  }

  // Upstream closed without a task_result frame.
  controller.enqueue(
    contentChunks === 0
      ? sseBytes({ error: 'agent stream closed unexpectedly' })
      : DONE_BYTES,
  );
}
