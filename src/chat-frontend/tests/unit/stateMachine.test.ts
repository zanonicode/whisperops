import { describe, it, expect, vi } from 'vitest';
import { StreamFSM } from '@/lib/kagent/stateMachine';
import type { NormalizedEvent, StatusUpdate, ArtifactUpdate } from '@/lib/kagent/types';

function makeStatus(overrides: Partial<StatusUpdate> = {}): StatusUpdate {
  return {
    kind: 'status-update',
    final: false,
    status: { state: 'working' },
    metadata: {},
    ...overrides,
  } as StatusUpdate;
}

function makeArtifact(overrides: Partial<ArtifactUpdate> = {}): ArtifactUpdate {
  return {
    kind: 'artifact-update',
    lastChunk: false,
    artifact: { parts: [{ kind: 'text', text: 'hello' }] },
    ...overrides,
  } as ArtifactUpdate;
}

describe('StreamFSM', () => {
  it('starts in WAITING_FOR_TASK', () => {
    const fsm = new StreamFSM(vi.fn());
    expect(fsm.getState()).toBe('WAITING_FOR_TASK');
  });

  it('transitions to WORKING on submitted status', () => {
    const emit = vi.fn();
    const fsm = new StreamFSM(emit);
    fsm.onStatusUpdate(makeStatus({ status: { state: 'submitted' } }));
    expect(fsm.getState()).toBe('WORKING');
    expect(emit).toHaveBeenCalledWith(expect.objectContaining({ type: 'submitted' }));
  });

  it('emits author event on working status with author', () => {
    const emit = vi.fn();
    const fsm = new StreamFSM(emit);
    fsm.onStatusUpdate(
      makeStatus({ metadata: { kagent_author: 'analyst' } })
    );
    expect(emit).toHaveBeenCalledWith(expect.objectContaining({ type: 'author', author: 'analyst' }));
  });

  it('emits terminal on final status-update', () => {
    const emit = vi.fn();
    const fsm = new StreamFSM(emit);
    fsm.onStatusUpdate(makeStatus({ final: true }));
    expect(fsm.getState()).toBe('DONE');
    const events: NormalizedEvent[] = emit.mock.calls.map((c: [NormalizedEvent]) => c[0]);
    expect(events.some((e) => e.type === 'terminal')).toBe(true);
  });

  it('emits terminal on artifact lastChunk', () => {
    const emit = vi.fn();
    const fsm = new StreamFSM(emit);
    fsm.onArtifactUpdate(makeArtifact({ lastChunk: true }));
    expect(fsm.getState()).toBe('DONE');
    expect(emit).toHaveBeenCalledWith(expect.objectContaining({ type: 'terminal', reason: 'lastChunk' }));
  });

  it('is idempotent — second terminal signal does not re-emit', () => {
    const emit = vi.fn();
    const fsm = new StreamFSM(emit);
    fsm.onArtifactUpdate(makeArtifact({ lastChunk: true }));
    const firstCount = emit.mock.calls.length;
    fsm.onStatusUpdate(makeStatus({ final: true }));
    expect(emit.mock.calls.length).toBe(firstCount);
  });

  it('emits artifact text', () => {
    const emit = vi.fn();
    const fsm = new StreamFSM(emit);
    fsm.onArtifactUpdate(makeArtifact({ lastChunk: false }));
    expect(emit).toHaveBeenCalledWith(expect.objectContaining({ type: 'artifact', text: 'hello' }));
    expect(fsm.getState()).toBe('ARTIFACT_RECEIVED');
  });
});
