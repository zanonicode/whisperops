'use client';

import { motion } from 'motion/react';
import { cn } from '@/lib/cn';
import { MarkdownContent } from './MarkdownContent';
import { StatusPill } from './StatusPill';

export type MessageRole = 'user' | 'assistant';
export type MessageStatus = 'pending' | 'streaming' | 'completed' | 'failed';

export interface MessageData {
  id: string;
  role: MessageRole;
  text: string;
  status: MessageStatus;
  author?: string;
}

interface MessageProps {
  msg: MessageData;
}

export function Message({ msg }: MessageProps) {
  const isUser = msg.role === 'user';
  const isStreaming = msg.status === 'streaming' || msg.status === 'pending';

  return (
    <motion.div
      layout
      initial={{ opacity: 0, y: 4 }}
      animate={{ opacity: 1, y: 0 }}
      transition={{ duration: 0.2, ease: 'easeOut' }}
      className={cn('flex w-full gap-3', isUser ? 'justify-end' : 'justify-start')}
    >
      <div
        className={cn(
          'max-w-[85%] rounded-2xl px-4 py-3',
          isUser
            ? 'bg-accent text-accent-foreground'
            : 'bg-white/[0.03] ring-1 ring-white/10'
        )}
      >
        {!isUser && (
          <div className="mb-1">
            <StatusPill author={msg.author} visible={isStreaming} />
          </div>
        )}
        <div
          aria-live={isStreaming ? 'polite' : undefined}
          className="prose prose-invert max-w-none text-[15px] leading-relaxed"
        >
          {msg.text ? (
            <MarkdownContent text={msg.text} />
          ) : isStreaming ? (
            <span className="animate-pulse text-muted-foreground">…</span>
          ) : null}
        </div>
        {msg.status === 'failed' && (
          <p className="mt-2 text-xs text-red-400">
            This message may be incomplete. You can retry.
          </p>
        )}
      </div>
    </motion.div>
  );
}
