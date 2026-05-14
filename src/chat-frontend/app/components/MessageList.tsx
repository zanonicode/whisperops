'use client';

import { useEffect, useRef } from 'react';
import { AnimatePresence } from 'motion/react';
import { Message } from './Message';
import type { MessageData } from './Message';

interface MessageListProps {
  messages: MessageData[];
  isStreaming: boolean;
}

export function MessageList({ messages, isStreaming }: MessageListProps) {
  const bottomRef = useRef<HTMLDivElement>(null);
  const listRef = useRef<HTMLDivElement>(null);
  const userScrolledRef = useRef(false);

  useEffect(() => {
    const list = listRef.current;
    if (!list) return;

    const handleScroll = () => {
      const { scrollTop, scrollHeight, clientHeight } = list;
      const distanceFromBottom = scrollHeight - scrollTop - clientHeight;
      userScrolledRef.current = distanceFromBottom > 80;
    };

    list.addEventListener('scroll', handleScroll, { passive: true });
    return () => list.removeEventListener('scroll', handleScroll);
  }, []);

  useEffect(() => {
    if (!isStreaming) {
      userScrolledRef.current = false;
    }
    if (!userScrolledRef.current) {
      bottomRef.current?.scrollIntoView({ behavior: 'smooth', block: 'end' });
    }
  }, [messages, isStreaming]);

  if (messages.length === 0) {
    return (
      <div className="flex flex-1 items-center justify-center">
        <p className="text-sm text-muted-foreground">Send a message to start the conversation.</p>
      </div>
    );
  }

  return (
    <div
      ref={listRef}
      className="flex flex-1 flex-col gap-4 overflow-y-auto px-4 py-6 scroll-smooth"
      aria-label="Conversation"
      role="log"
      aria-live="polite"
      aria-relevant="additions"
    >
      <AnimatePresence initial={false}>
        {messages.map((msg) => (
          <Message key={msg.id} msg={msg} />
        ))}
      </AnimatePresence>
      <div ref={bottomRef} aria-hidden="true" />
    </div>
  );
}
