'use client';

import { AnimatePresence, motion } from 'motion/react';
import { useEffect, useState } from 'react';
import { cn } from '@/lib/cn';

const LABELS: Record<string, string> = {
  planner: 'Planner thinking…',
  analyst: 'Analyst computing…',
  writer: 'Writer drafting…',
};

const DOT_CLASS: Record<string, string> = {
  planner: 'bg-accent',
  analyst: 'bg-emerald-400',
  writer: 'bg-fuchsia-400',
};

interface StatusPillProps {
  author?: string;
  visible: boolean;
}

export function StatusPill({ author, visible }: StatusPillProps) {
  const [debouncedAuthor, setDebouncedAuthor] = useState(author ?? 'planner');

  useEffect(() => {
    if (!author) return;
    const id = setTimeout(() => setDebouncedAuthor(author), 200);
    return () => clearTimeout(id);
  }, [author]);

  return (
    <AnimatePresence mode="wait">
      {visible && (
        <motion.div
          key={debouncedAuthor}
          initial={{ opacity: 0, y: 4 }}
          animate={{ opacity: 1, y: 0 }}
          exit={{ opacity: 0, y: -2 }}
          transition={{ duration: 0.2, ease: 'easeOut' }}
          role="status"
          aria-live="polite"
          aria-label={LABELS[debouncedAuthor] ?? 'Processing…'}
          className={cn(
            'inline-flex items-center gap-2 rounded-full px-3 py-1',
            'text-xs font-medium text-foreground/80',
            'bg-white/[0.04] ring-1 ring-white/10 backdrop-blur-sm'
          )}
        >
          <span
            className={cn(
              'inline-block size-2 rounded-full',
              DOT_CLASS[debouncedAuthor] ?? 'bg-foreground/30',
              'animate-pulse'
            )}
          />
          {LABELS[debouncedAuthor] ?? 'Processing…'}
        </motion.div>
      )}
    </AnimatePresence>
  );
}
