'use client';

import { useState, useRef, type KeyboardEvent } from 'react';
import { ArrowUp, Square } from 'lucide-react';
import { cn } from '@/lib/cn';

interface ComposerProps {
  onSend: (text: string) => void;
  isStreaming: boolean;
  disabled?: boolean;
  placeholder?: string;
}

export function Composer({ onSend, isStreaming, disabled, placeholder }: ComposerProps) {
  const [text, setText] = useState('');
  const textareaRef = useRef<HTMLTextAreaElement>(null);

  const canSend = text.trim().length > 0 && !isStreaming && !disabled;

  const handleSend = () => {
    if (!canSend) return;
    const trimmed = text.trim();
    setText('');
    if (textareaRef.current) {
      textareaRef.current.style.height = 'auto';
    }
    onSend(trimmed);
  };

  const handleKeyDown = (e: KeyboardEvent<HTMLTextAreaElement>) => {
    if (e.key === 'Enter' && !e.shiftKey) {
      e.preventDefault();
      handleSend();
    }
  };

  const handleInput = () => {
    const el = textareaRef.current;
    if (!el) return;
    el.style.height = 'auto';
    el.style.height = `${Math.min(el.scrollHeight, 200)}px`;
  };

  return (
    <div className="px-4 pb-4 pt-2">
      <div
        className={cn(
          'flex items-end gap-2 rounded-2xl px-4 py-3',
          'glass ring-1 ring-white/10',
          'focus-within:ring-accent/50 transition-all'
        )}
      >
        <textarea
          ref={textareaRef}
          rows={1}
          value={text}
          onChange={(e) => setText(e.target.value)}
          onKeyDown={handleKeyDown}
          onInput={handleInput}
          placeholder={placeholder ?? 'Ask a question about your dataset…'}
          disabled={disabled}
          aria-label="Message input"
          className={cn(
            'flex-1 resize-none bg-transparent text-sm text-foreground outline-none',
            'placeholder:text-muted-foreground',
            'max-h-[200px] scrollbar-none',
            disabled && 'cursor-not-allowed opacity-50'
          )}
        />
        <button
          onClick={handleSend}
          disabled={!canSend}
          aria-label={isStreaming ? 'Stop generation' : 'Send message'}
          className={cn(
            'shrink-0 rounded-xl p-2 transition-all',
            'focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring',
            canSend
              ? 'bg-accent text-accent-foreground hover:bg-accent/90'
              : 'bg-white/5 text-muted-foreground cursor-not-allowed'
          )}
        >
          {isStreaming ? <Square className="size-4" /> : <ArrowUp className="size-4" />}
        </button>
      </div>
      <p className="mt-2 text-center text-xs text-muted-foreground/60">
        Press Enter to send · Shift+Enter for new line
      </p>
    </div>
  );
}
