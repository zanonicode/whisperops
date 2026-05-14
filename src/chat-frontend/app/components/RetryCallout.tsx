'use client';

import { AlertCircle } from 'lucide-react';
import { cn } from '@/lib/cn';

interface RetryCalloutProps {
  onRetry: () => void;
  className?: string;
}

export function RetryCallout({ onRetry, className }: RetryCalloutProps) {
  return (
    <div
      role="alert"
      className={cn(
        'flex items-center gap-3 rounded-xl px-4 py-3',
        'bg-red-500/10 ring-1 ring-red-500/30 text-red-400',
        'text-sm',
        className
      )}
    >
      <AlertCircle className="size-4 shrink-0" />
      <span className="flex-1">Connection lost. The last response may be incomplete.</span>
      <button
        onClick={onRetry}
        className={cn(
          'ml-2 rounded-md px-3 py-1 text-xs font-medium',
          'bg-red-500/20 hover:bg-red-500/30 transition-colors',
          'focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-red-500'
        )}
      >
        Retry
      </button>
    </div>
  );
}
