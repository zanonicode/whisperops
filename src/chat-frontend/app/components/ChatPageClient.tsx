'use client';

import { useState, useCallback, useEffect } from 'react';
import { Header } from './Header';
import { MessageList } from './MessageList';
import { Composer } from './Composer';
import { RetryCallout } from './RetryCallout';
import { ErrorBoundary } from './ErrorBoundary';
import { useChatStream } from '@/hooks/useChatStream';
import { useAgentCard } from '@/hooks/useAgentCard';
import { useThreads } from '@/hooks/useThreads';
import type { MessageData } from './Message';

interface ChatPageClientProps {
  agentName: string;
}

export function ChatPageClient({ agentName }: ChatPageClientProps) {
  const { card } = useAgentCard();
  const { messages, isStreaming, send, retry, reset } = useChatStream();
  const {
    threads,
    activeThread,
    activeThreadId,
    addThread,
    setContextId,
  } = useThreads(agentName);

  const [lastInput, setLastInput] = useState('');

  useEffect(() => {
    if (!activeThreadId && threads.length === 0) {
      addThread('Conversation');
    }
  }, [activeThreadId, threads.length, addThread]);

  const hasFailed = messages.some((m) => m.status === 'failed');
  const contextId = activeThread?.contextId ?? undefined;

  const handleSend = useCallback(
    async (text: string) => {
      setLastInput(text);
      const result = await send(text, contextId);
      if (result.contextId && activeThreadId) {
        setContextId(activeThreadId, result.contextId);
      }
    },
    [send, contextId, activeThreadId, setContextId]
  );

  const handleRetry = useCallback(async () => {
    if (!lastInput) return;
    const result = await retry(lastInput, contextId);
    if (result.contextId && activeThreadId) {
      setContextId(activeThreadId, result.contextId);
    }
  }, [retry, lastInput, contextId, activeThreadId, setContextId]);

  const handleNewConversation = useCallback(() => {
    reset();
    addThread('Conversation');
  }, [reset, addThread]);

  const msgData: MessageData[] = messages.map((m) => ({
    id: m.id,
    role: m.role,
    text: m.text,
    status: m.status,
    author: m.author,
  }));

  return (
    <div className="flex h-screen overflow-hidden bg-background text-foreground">
      <div className="flex flex-1 flex-col min-w-0">
        <Header card={card} onNewConversation={handleNewConversation} />
        <main id="main-content" className="flex flex-1 flex-col min-h-0">
          <ErrorBoundary>
            <MessageList messages={msgData} isStreaming={isStreaming} />
          </ErrorBoundary>

          {hasFailed && (
            <div className="px-4 pb-2">
              <RetryCallout onRetry={handleRetry} />
            </div>
          )}

          <Composer
            onSend={handleSend}
            isStreaming={isStreaming}
            placeholder={card ? `Ask ${card.name} about your dataset…` : undefined}
          />
        </main>
      </div>
    </div>
  );
}
