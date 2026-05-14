import type { StatusUpdate, ArtifactUpdate, MessagePart, NormalizedEvent } from './types';
import { extractTextFromParts } from './sseParser';

function extractSubAgentFromCalls(parts: MessagePart[] | undefined): string | undefined {
  if (!parts) return undefined;
  for (const p of parts) {
    if (p.kind !== 'data' || p.metadata?.kagent_type !== 'function_call') continue;
    const name = (p.data as { name?: unknown })?.name;
    if (typeof name !== 'string') continue;
    const m = name.match(/__NS__(.+)$/);
    if (m && (m[1] === 'analyst' || m[1] === 'writer')) return m[1];
  }
  return undefined;
}

export type StreamState = 'WAITING_FOR_TASK' | 'WORKING' | 'ARTIFACT_RECEIVED' | 'DONE';

export class StreamFSM {
  private state: StreamState = 'WAITING_FOR_TASK';
  private closed = false;

  constructor(private emit: (e: NormalizedEvent) => void) {}

  getState(): StreamState {
    return this.state;
  }

  onStatusUpdate(s: StatusUpdate): void {
    if (this.closed) return;
    const author = s.metadata?.kagent_author;
    const text = extractTextFromParts(s.status?.message?.parts);
    const usage = s.metadata?.kagent_usage_metadata;
    const subAgent = extractSubAgentFromCalls(s.status?.message?.parts);

    if (s.status?.state === 'submitted') {
      this.state = 'WORKING';
      this.emit({ type: 'submitted' });
      return;
    }
    if (s.status?.state === 'working') {
      this.state = 'WORKING';
      if (text) this.emit({ type: 'text', text, author });
      if (subAgent) this.emit({ type: 'author', author: subAgent });
      else if (author) this.emit({ type: 'author', author });
      if (usage) this.emit({ type: 'usage', usage });
      return;
    }
    if (s.final === true) {
      if (usage) this.emit({ type: 'usage', usage });
      this.closeStream({ reason: 'final' });
      return;
    }
    if (s.status?.state === 'failed') {
      this.closeStream({ reason: 'failed' });
    }
  }

  onArtifactUpdate(a: ArtifactUpdate): void {
    if (this.closed) return;
    const text = extractTextFromParts(a.artifact?.parts);
    this.state = 'ARTIFACT_RECEIVED';
    if (text) this.emit({ type: 'artifact', text });
    if (a.lastChunk === true) {
      this.closeStream({ reason: 'lastChunk' });
    }
  }

  private closeStream(payload: { reason: 'final' | 'lastChunk' | 'failed' }): void {
    if (this.closed) return;
    this.closed = true;
    this.state = 'DONE';
    this.emit({ type: 'terminal', reason: payload.reason });
  }
}
