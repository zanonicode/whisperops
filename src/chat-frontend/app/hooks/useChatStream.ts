'use client';

import { useCallback, useRef, useState } from 'react';
import { newId } from '@/lib/id';

export type MessageRole = 'user' | 'assistant';
export type MessageStatus = 'pending' | 'streaming' | 'completed' | 'failed';

export interface ChatMessage {
  id: string;
  role: MessageRole;
  text: string;
  status: MessageStatus;
  author?: string;
}

interface UseChatStreamReturn {
  messages: ChatMessage[];
  streamingAuthor: string | null;
  isStreaming: boolean;
  send: (text: string, contextId?: string) => Promise<{ contextId?: string }>;
  retry: (text: string, contextId?: string) => Promise<{ contextId?: string }>;
  reset: () => void;
  setMessages: React.Dispatch<React.SetStateAction<ChatMessage[]>>;
}

interface ServerEvent {
  kind: string;
  state?: string;
  text?: string;
  author?: string;
  reason?: string;
  message?: string;
  usage?: Record<string, number>;
}

type StreamOutcome =
  | { kind: 'success'; contextId?: string }
  | { kind: 'retryable'; contextId?: string }
  | { kind: 'fatal'; message: string; contextId?: string };

// Errors that warrant a transparent one-shot retry. These are upstream-side
// stochastic failures where re-sending the same message often succeeds — the
// canonical case is kagent v0.9.x's ADK closing the SSE without emitting a
// terminal `final:true` after Gemini emits a part the part_converter rejects.
const RETRYABLE_ERROR_PATTERNS = ['stream closed without terminal signal'];

function isRetryableError(message: string | undefined): boolean {
  if (!message) return false;
  return RETRYABLE_ERROR_PATTERNS.some((p) => message.includes(p));
}

export function useChatStream(): UseChatStreamReturn {
  const [messages, setMessages] = useState<ChatMessage[]>([]);
  const [isStreaming, setIsStreaming] = useState(false);
  const [streamingAuthor, setStreamingAuthor] = useState<string | null>(null);

  const rafRef = useRef<number | null>(null);
  const textBufRef = useRef('');
  const artifactBufRef = useRef('');
  const activeIdRef = useRef<string | null>(null);
  const authorDebounceRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const streamClosedRef = useRef(false);

  const flushBuf = useCallback(() => {
    if (!textBufRef.current && !artifactBufRef.current) return;
    const id = activeIdRef.current;
    if (!id) return;

    const delta = textBufRef.current;
    textBufRef.current = '';

    if (delta) {
      setMessages((prev) =>
        prev.map((m) =>
          m.id === id ? { ...m, text: m.text + delta } : m
        )
      );
    }

    rafRef.current = requestAnimationFrame(flushBuf);
  }, []);

  const scheduleFlush = useCallback(() => {
    if (rafRef.current === null) {
      rafRef.current = requestAnimationFrame(flushBuf);
    }
  }, [flushBuf]);

  const stopFlush = useCallback(() => {
    if (rafRef.current !== null) {
      cancelAnimationFrame(rafRef.current);
      rafRef.current = null;
    }
  }, []);

  const attemptStream = useCallback(
    async (
      text: string,
      contextId: string | undefined,
      asstMsgId: string,
      isRetry: boolean,
    ): Promise<StreamOutcome> => {
      streamClosedRef.current = false;
      textBufRef.current = '';
      artifactBufRef.current = '';

      let resolvedContextId: string | undefined;

      try {
        const res = await fetch('/api/chat', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ text, contextId }),
        });

        if (!res.ok || !res.body) {
          return { kind: 'fatal', message: `HTTP ${res.status}` };
        }

        setMessages((prev) =>
          prev.map((m) =>
            m.id === asstMsgId ? { ...m, status: 'streaming' } : m
          )
        );

        scheduleFlush();

        const reader = res.body.getReader();
        const decoder = new TextDecoder();
        let buf = '';
        let retryableErrorSeen = false;
        let fatalMessage: string | undefined;

        while (true) {
          const { done, value } = await reader.read();
          if (done) break;

          buf += decoder.decode(value, { stream: true });

          let nl: number;
          while ((nl = buf.indexOf('\n\n')) !== -1) {
            const block = buf.slice(0, nl);
            buf = buf.slice(nl + 2);

            let eventType = '';
            for (const line of block.split('\n')) {
              if (line.startsWith('event:')) {
                eventType = line.slice(6).trim();
              } else if (line.startsWith('data:')) {
                const json = line.slice(5).trim();
                if (!json) continue;

                try {
                  if (eventType === 'trace-context') {
                    const tc = JSON.parse(json) as { traceparent?: string };
                    if (tc.traceparent) {
                      // Browser OTel join — context available for future instrumentation
                    }
                    continue;
                  }

                  if (eventType === 'context') {
                    const c = JSON.parse(json) as { contextId?: string };
                    if (c.contextId) resolvedContextId = c.contextId;
                    continue;
                  }

                  const evt = JSON.parse(json) as ServerEvent;

                  if (eventType === 'status') {
                    if (evt.author) {
                      if (authorDebounceRef.current) {
                        clearTimeout(authorDebounceRef.current);
                      }
                      const capturedAuthor = evt.author;
                      authorDebounceRef.current = setTimeout(() => {
                        setStreamingAuthor(capturedAuthor);
                        setMessages((prev) =>
                          prev.map((m) =>
                            m.id === asstMsgId ? { ...m, author: capturedAuthor } : m
                          )
                        );
                      }, 200);
                    }
                  } else if (eventType === 'artifact') {
                    if (evt.kind === 'text-delta' && evt.text) {
                      textBufRef.current += evt.text;
                      scheduleFlush();
                    } else if (evt.kind === 'artifact' && evt.text) {
                      artifactBufRef.current = evt.text;
                    }
                  } else if (eventType === 'terminal') {
                    if (!streamClosedRef.current) {
                      streamClosedRef.current = true;
                      stopFlush();

                      const finalText = artifactBufRef.current || undefined;
                      setMessages((prev) =>
                        prev.map((m) =>
                          m.id === asstMsgId
                            ? {
                                ...m,
                                text: finalText ?? m.text + textBufRef.current,
                                status: 'completed',
                              }
                            : m
                        )
                      );
                      textBufRef.current = '';
                      artifactBufRef.current = '';
                      setStreamingAuthor(null);
                    }
                  } else if (eventType === 'error') {
                    if (!isRetry && isRetryableError(evt.message)) {
                      retryableErrorSeen = true;
                      // Don't write the error into the message — caller will retry.
                      // Reset partial buffers so the retry starts clean.
                      stopFlush();
                      textBufRef.current = '';
                      artifactBufRef.current = '';
                      setStreamingAuthor(null);
                    } else {
                      fatalMessage = evt.message ?? 'An error occurred.';
                      stopFlush();
                      setMessages((prev) =>
                        prev.map((m) =>
                          m.id === asstMsgId
                            ? { ...m, text: fatalMessage ?? '', status: 'failed' }
                            : m
                        )
                      );
                    }
                  }
                } catch {
                  // Ignore malformed event lines
                }
              }
            }
          }
        }

        if (retryableErrorSeen) {
          return { kind: 'retryable', contextId: resolvedContextId };
        }

        if (fatalMessage) {
          return { kind: 'fatal', message: fatalMessage, contextId: resolvedContextId };
        }

        if (streamClosedRef.current) {
          return { kind: 'success', contextId: resolvedContextId };
        }

        // Upstream closed without a terminal event and without an error event.
        // Treat as retryable on first attempt (same recovery as the named
        // "stream closed without terminal signal" error) — flush partial text
        // so the user sees progress on the failed message if we don't retry.
        stopFlush();
        if (!isRetry) {
          textBufRef.current = '';
          artifactBufRef.current = '';
          return { kind: 'retryable', contextId: resolvedContextId };
        }
        setMessages((prev) =>
          prev.map((m) =>
            m.id === asstMsgId && m.status === 'streaming'
              ? { ...m, status: 'failed', text: m.text + textBufRef.current }
              : m
          )
        );
        textBufRef.current = '';
        return {
          kind: 'fatal',
          message: 'Connection closed unexpectedly',
          contextId: resolvedContextId,
        };
      } catch (err) {
        stopFlush();
        const message = err instanceof Error ? err.message : 'Connection error';
        setMessages((prev) =>
          prev.map((m) =>
            m.id === asstMsgId ? { ...m, text: message, status: 'failed' } : m
          )
        );
        return { kind: 'fatal', message, contextId: resolvedContextId };
      }
    },
    [scheduleFlush, stopFlush],
  );

  const sendRequest = useCallback(
    async (text: string, contextId?: string): Promise<{ contextId?: string }> => {
      if (isStreaming) return {};

      const userMsgId = newId();
      const asstMsgId = newId();
      activeIdRef.current = asstMsgId;

      setMessages((prev) => [
        ...prev,
        { id: userMsgId, role: 'user', text, status: 'completed' },
        { id: asstMsgId, role: 'assistant', text: '', status: 'pending' },
      ]);
      setIsStreaming(true);
      setStreamingAuthor(null);

      let outcome: StreamOutcome = { kind: 'fatal', message: 'init' };
      try {
        for (let attempt = 0; attempt < 2; attempt++) {
          if (attempt > 0) {
            // Retry: reset the assistant message to a clean pending state.
            setMessages((prev) =>
              prev.map((m) =>
                m.id === asstMsgId
                  ? { ...m, text: '', status: 'pending', author: undefined }
                  : m
              )
            );
            setStreamingAuthor(null);
          }
          outcome = await attemptStream(text, contextId, asstMsgId, attempt > 0);
          if (outcome.kind !== 'retryable') break;
        }
      } finally {
        setIsStreaming(false);
        activeIdRef.current = null;
        if (authorDebounceRef.current) {
          clearTimeout(authorDebounceRef.current);
        }
      }

      return { contextId: outcome.contextId };
    },
    [isStreaming, attemptStream],
  );

  const reset = useCallback(() => {
    setMessages([]);
    setIsStreaming(false);
    setStreamingAuthor(null);
    textBufRef.current = '';
    artifactBufRef.current = '';
    activeIdRef.current = null;
  }, []);

  return {
    messages,
    streamingAuthor,
    isStreaming,
    send: sendRequest,
    retry: sendRequest,
    reset,
    setMessages,
  };
}
