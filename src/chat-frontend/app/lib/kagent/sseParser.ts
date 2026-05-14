import type { JsonRpcEnvelope, StatusUpdate, ArtifactUpdate } from './types';

type AnyEvent = StatusUpdate | ArtifactUpdate;
type Handler = (event: AnyEvent, raw: JsonRpcEnvelope) => void;

export async function parseSSEChunks(
  body: ReadableStream<Uint8Array>,
  onEvent: Handler,
  signal?: AbortSignal,
): Promise<void> {
  const reader = body.getReader();
  const decoder = new TextDecoder('utf-8');
  let buf = '';

  try {
    while (true) {
      if (signal?.aborted) {
        await reader.cancel();
        throw new DOMException('Aborted', 'AbortError');
      }
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
            const env = JSON.parse(json) as JsonRpcEnvelope;
            if (!env.result) continue;
            const kind = (env.result as { kind?: string }).kind;
            if (kind === 'status-update') {
              onEvent(env.result as StatusUpdate, env);
            } else if (kind === 'artifact-update') {
              onEvent(env.result as ArtifactUpdate, env);
            }
          } catch {
            // Ignore malformed line per SSE spec
          }
        }
      }
    }
  } finally {
    reader.releaseLock();
  }
}

export function extractTextFromParts(
  parts: Array<{ kind: string; text?: string }> | undefined,
): string {
  if (!parts) return '';
  return parts
    .filter((p) => p.kind === 'text')
    .map((p) => p.text ?? '')
    .join('');
}
