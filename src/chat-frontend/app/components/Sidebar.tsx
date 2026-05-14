'use client';

import { Plus, Trash2, MessageSquare } from 'lucide-react';
import { motion, AnimatePresence } from 'motion/react';
import { cn } from '@/lib/cn';
import type { Thread } from '@/lib/threads';

interface SidebarProps {
  threads: Thread[];
  activeThreadId: string | null;
  onNewThread: () => void;
  onSelectThread: (id: string) => void;
  onDeleteThread: (id: string) => void;
}

export function Sidebar({
  threads,
  activeThreadId,
  onNewThread,
  onSelectThread,
  onDeleteThread,
}: SidebarProps) {
  return (
    <aside
      className="flex h-full w-64 flex-col border-r border-white/[0.06] bg-black/20"
      aria-label="Conversation history"
    >
      <div className="flex items-center justify-between px-4 py-3 border-b border-white/[0.06]">
        <span className="text-xs font-medium text-muted-foreground uppercase tracking-wider">
          Threads
        </span>
        <button
          onClick={onNewThread}
          aria-label="New conversation"
          className={cn(
            'rounded-md p-1.5 text-muted-foreground transition-colors',
            'hover:text-foreground hover:bg-white/10',
            'focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring'
          )}
        >
          <Plus className="size-4" />
        </button>
      </div>

      <nav className="flex-1 overflow-y-auto py-2" aria-label="Conversation threads">
        {threads.length === 0 ? (
          <p className="px-4 py-3 text-xs text-muted-foreground/60">No conversations yet.</p>
        ) : (
          <AnimatePresence initial={false}>
            {threads.map((thread) => (
              <motion.div
                key={thread.id}
                initial={{ opacity: 0, x: -8 }}
                animate={{ opacity: 1, x: 0 }}
                exit={{ opacity: 0, x: -8 }}
                transition={{ duration: 0.15 }}
                className="group relative"
              >
                <button
                  onClick={() => onSelectThread(thread.id)}
                  aria-current={thread.id === activeThreadId ? 'page' : undefined}
                  className={cn(
                    'flex w-full items-center gap-2 px-4 py-2.5 text-left text-sm transition-colors',
                    'hover:bg-white/[0.04]',
                    thread.id === activeThreadId
                      ? 'bg-white/[0.06] text-foreground'
                      : 'text-muted-foreground'
                  )}
                >
                  <MessageSquare className="size-3.5 shrink-0 opacity-50" />
                  <span className="flex-1 truncate">{thread.title}</span>
                </button>
                <button
                  onClick={(e) => {
                    e.stopPropagation();
                    onDeleteThread(thread.id);
                  }}
                  aria-label={`Delete thread: ${thread.title}`}
                  className={cn(
                    'absolute right-2 top-1/2 -translate-y-1/2',
                    'rounded-md p-1 opacity-0 transition-opacity',
                    'group-hover:opacity-100',
                    'text-muted-foreground hover:text-red-400 hover:bg-red-500/10',
                    'focus-visible:opacity-100 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring'
                  )}
                >
                  <Trash2 className="size-3.5" />
                </button>
              </motion.div>
            ))}
          </AnimatePresence>
        )}
      </nav>
    </aside>
  );
}
