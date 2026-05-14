import type { JsonRpcEnvelope } from './types';

function sseEvent(eventName: string, data: unknown): Uint8Array {
  return new TextEncoder().encode(
    `event: ${eventName}\ndata: ${JSON.stringify(data)}\n\n`
  );
}

interface SendFallbackOptions {
  plannerUrl: string;
  envelope: Record<string, unknown>;
}

export async function runSendFallback(opts: SendFallbackOptions): Promise<Response> {
  const headers: Record<string, string> = {
    'Content-Type': 'text/event-stream',
    'Cache-Control': 'no-cache, no-transform',
    Connection: 'keep-alive',
    'X-Accel-Buffering': 'no',
  };

  const stream = new ReadableStream<Uint8Array>({
    async start(controller) {
      controller.enqueue(sseEvent('status', { kind: 'status', state: 'submitted' }));
      controller.enqueue(sseEvent('status', { kind: 'author', author: 'planner' }));

      try {
        const res = await fetch(`${opts.plannerUrl}/`, {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
          },
          body: JSON.stringify(opts.envelope),
        });

        if (!res.ok) {
          const text = await res.text().catch(() => '');
          controller.enqueue(
            sseEvent('error', { kind: 'error', message: `planner ${res.status}: ${text}` })
          );
          controller.close();
          return;
        }

        const body = (await res.json()) as JsonRpcEnvelope;

        if (body.error) {
          controller.enqueue(
            sseEvent('error', { kind: 'error', message: body.error.message, code: body.error.code })
          );
          controller.close();
          return;
        }

        const result = body.result as {
          parts?: Array<{ kind: string; text?: string }>;
          message?: { parts?: Array<{ kind: string; text?: string }> };
        } | undefined;

        const parts = result?.parts ?? result?.message?.parts ?? [];
        const fullText = parts
          .filter((p) => p.kind === 'text')
          .map((p) => p.text ?? '')
          .join('');

        const CHUNK_SIZE = 6;
        const INTERVAL_MS = 33;

        for (let i = 0; i < fullText.length; i += CHUNK_SIZE) {
          const chunk = fullText.slice(i, i + CHUNK_SIZE);
          controller.enqueue(sseEvent('artifact', { kind: 'text-delta', text: chunk, author: 'planner' }));
          await new Promise((resolve) => setTimeout(resolve, INTERVAL_MS));
        }

        controller.enqueue(sseEvent('artifact', { kind: 'artifact', text: fullText }));
        controller.enqueue(sseEvent('terminal', { kind: 'terminal', reason: 'final' }));
      } catch (err) {
        const message = err instanceof Error ? err.message : 'send fallback failed';
        controller.enqueue(sseEvent('error', { kind: 'error', message }));
      } finally {
        controller.close();
      }
    },
  });

  return new Response(stream, { headers });
}
