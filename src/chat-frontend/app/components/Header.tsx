'use client';

import { Plus } from 'lucide-react';
import { cn } from '@/lib/cn';
import { ThemeToggle } from './ThemeToggle';
import type { AgentCard } from '@/lib/kagent/types';

interface HeaderProps {
  card: AgentCard | null;
  onNewConversation?: () => void;
}

export function Header({ card, onNewConversation }: HeaderProps) {
  const name = card?.name ?? 'Dataset Whisperer';
  const description = card?.description;

  return (
    <header
      className={cn(
        'flex items-center gap-3 px-4 py-3',
        'border-b border-white/[0.06] glass',
        'sticky top-0 z-10'
      )}
    >
      <div className="flex-1 min-w-0">
        <h1 className="truncate text-sm font-semibold text-foreground">{name}</h1>
        {description && (
          <p className="truncate text-xs text-muted-foreground">{description}</p>
        )}
      </div>
      {onNewConversation && (
        <button
          onClick={onNewConversation}
          aria-label="New conversation"
          className={cn(
            'inline-flex items-center gap-1.5 rounded-md px-2.5 py-1.5 text-xs font-medium',
            'text-muted-foreground transition-colors',
            'hover:text-foreground hover:bg-white/10',
            'focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring'
          )}
        >
          <Plus className="size-3.5" />
          New
        </button>
      )}
      <ThemeToggle />
    </header>
  );
}
