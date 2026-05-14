import type { StatusUpdate, ArtifactUpdate } from './types';
import { StreamFSM } from './stateMachine';

interface RelayOptions {
  messageId: string;
  traceparent?: string;
}

function sseEvent(eventName: string, data: unknown): Uint8Array {
  return new TextEncoder().encode(
    `event: ${eventName}\ndata: ${JSON.stringify(data)}\n\n`
  );
}

export function createRelay(
  upstreamBody: ReadableStream<Uint8Array>,
  opts: RelayOptions,
): { stream: ReadableStream<Uint8Array>; headers: Record<string, string> } {
  const headers: Record<string, string> = {
    'Content-Type': 'text/event-stream',
    'Cache-Control': 'no-cache, no-transform',
    Connection: 'keep-alive',
    'X-Accel-Buffering': 'no',
  };

  const stream = new ReadableStream<Uint8Array>({
    async start(controller) {
      if (opts.traceparent) {
        controller.enqueue(
          sseEvent('trace-context', { traceparent: opts.traceparent })
        );
      }

      const decoder = new TextDecoder('utf-8');
      let buf = '';
      let contextEmitted = false;

      const fsm = new StreamFSM((event) => {
        switch (event.type) {
          case 'submitted':
            controller.enqueue(sseEvent('status', { kind: 'status', state: 'submitted' }));
            break;
          case 'text':
            controller.enqueue(
              sseEvent('artifact', {
                kind: 'text-delta',
                text: event.text,
                author: event.author,
              })
            );
            break;
          case 'author':
            controller.enqueue(
              sseEvent('status', { kind: 'author', author: event.author })
            );
            break;
          case 'artifact':
            controller.enqueue(
              sseEvent('artifact', { kind: 'artifact', text: event.text })
            );
            break;
          case 'terminal':
            controller.enqueue(
              sseEvent('terminal', { kind: 'terminal', reason: event.reason })
            );
            break;
          case 'usage':
            controller.enqueue(
              sseEvent('usage', { kind: 'usage', usage: event.usage })
            );
            break;
          case 'error':
            controller.enqueue(
              sseEvent('error', { kind: 'error', message: event.message })
            );
            break;
        }
      });

      const reader = upstreamBody.getReader();
      try {
        while (true) {
          const { done, value } = await reader.read();
          if (done) break;
          buf += decoder.decode(value, { stream: true }).replace(/\r\n/g, '\n');

          let nl: number;
          while ((nl = buf.indexOf('\n\n')) !== -1) {
            const block = buf.slice(0, nl);
            buf = buf.slice(nl + 2);

            for (const line of block.split('\n')) {
              if (!line.startsWith('data:')) continue;
              const json = line.slice(5).trim();
              if (!json) continue;
              try {
                const env = JSON.parse(json) as {
                  result?: { kind?: string } & Record<string, unknown>;
                  error?: { code: number; message: string };
                };
                if (env.error) {
                  controller.enqueue(
                    sseEvent('error', {
                      kind: 'error',
                      message: env.error.message,
                      code: env.error.code,
                    })
                  );
                  continue;
                }
                if (!env.result) continue;
                const ctx = (env.result as { contextId?: string }).contextId;
                if (ctx && !contextEmitted) {
                  contextEmitted = true;
                  controller.enqueue(sseEvent('context', { contextId: ctx }));
                }
                const kind = env.result.kind;
                if (kind === 'status-update') {
                  fsm.onStatusUpdate(env.result as unknown as StatusUpdate);
                } else if (kind === 'artifact-update') {
                  fsm.onArtifactUpdate(env.result as unknown as ArtifactUpdate);
                }
              } catch {
                // Ignore malformed lines
              }
            }
          }
        }

        if (fsm.getState() !== 'DONE') {
          controller.enqueue(
            sseEvent('error', {
              kind: 'error',
              message: 'stream closed without terminal signal',
            })
          );
        }
      } catch (err) {
        const message = err instanceof Error ? err.message : 'relay error';
        controller.enqueue(sseEvent('error', { kind: 'error', message }));
      } finally {
        reader.releaseLock();
        controller.close();
      }
    },
  });

  return { stream, headers };
}
