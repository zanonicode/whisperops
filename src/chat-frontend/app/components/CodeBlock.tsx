'use client';

import { useState, type ComponentPropsWithoutRef } from 'react';
import { Copy, Check } from 'lucide-react';
import { cn } from '@/lib/cn';

interface CodeBlockProps extends ComponentPropsWithoutRef<'code'> {
  language?: string;
}

export function CodeBlock({ language, children, className, ...rest }: CodeBlockProps) {
  const [copied, setCopied] = useState(false);
  const code = typeof children === 'string' ? children : String(children ?? '');

  const handleCopy = async () => {
    try {
      await navigator.clipboard.writeText(code);
      setCopied(true);
      setTimeout(() => setCopied(false), 2000);
    } catch {
      // Clipboard API unavailable
    }
  };

  return (
    <div className="group relative my-3">
      <pre
        className={cn(
          'overflow-x-auto rounded-xl bg-white/[0.04] ring-1 ring-white/10 p-4',
          'text-sm font-mono text-foreground/90',
          className
        )}
      >
        {language && (
          <span className="mb-2 block text-xs text-muted-foreground">{language}</span>
        )}
        <code {...rest}>{children}</code>
      </pre>
      <button
        onClick={handleCopy}
        aria-label="Copy code"
        className={cn(
          'absolute right-3 top-3 rounded-md p-1.5 opacity-0 transition-opacity',
          'group-hover:opacity-100 hover:bg-white/10',
          'text-muted-foreground hover:text-foreground',
          'focus-visible:opacity-100 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring'
        )}
      >
        {copied ? <Check className="size-4 text-emerald-400" /> : <Copy className="size-4" />}
      </button>
    </div>
  );
}
