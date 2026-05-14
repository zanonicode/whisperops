'use client';

import ReactMarkdown from 'react-markdown';
import remarkGfm from 'remark-gfm';
import { ImageDispatcher } from '@/lib/markdown';
import { CodeBlock } from './CodeBlock';
import { PlotlyChart } from './PlotlyChart';

interface MarkdownContentProps {
  text: string;
}

// react-markdown v10 may pass code-block content as a string, an array, or
// (less commonly) a React element tree. Robust extractor that tries every
// shape and falls back to String() if all else fails.
function extractCodeText(
  children: React.ReactNode,
  node: unknown,
): string {
  // Primary: walk the AST node hand-given by react-markdown.
  // A fenced code block AST has children[0].value containing the raw text.
  if (node && typeof node === 'object' && 'children' in (node as object)) {
    const astChildren = (node as { children?: unknown[] }).children;
    if (Array.isArray(astChildren)) {
      const parts: string[] = [];
      for (const c of astChildren) {
        if (c && typeof c === 'object' && 'value' in (c as object)) {
          const v = (c as { value: unknown }).value;
          if (typeof v === 'string') parts.push(v);
        }
      }
      if (parts.length > 0) return parts.join('');
    }
  }

  // Fallback: depth-first stringify of React children.
  const stack: React.ReactNode[] = [children];
  const out: string[] = [];
  while (stack.length > 0) {
    const cur = stack.pop();
    if (cur == null || typeof cur === 'boolean') continue;
    if (typeof cur === 'string' || typeof cur === 'number') {
      out.push(String(cur));
      continue;
    }
    if (Array.isArray(cur)) {
      for (let i = cur.length - 1; i >= 0; i--) stack.push(cur[i]);
      continue;
    }
    if (typeof cur === 'object' && 'props' in (cur as object)) {
      const p = (cur as { props?: { children?: React.ReactNode } }).props;
      if (p && 'children' in p) stack.push(p.children);
    }
  }
  if (out.length > 0) return out.join('');

  // Last resort.
  try {
    return String(children ?? '');
  } catch {
    return '';
  }
}

export function MarkdownContent({ text }: MarkdownContentProps) {
  return (
    <ReactMarkdown
      remarkPlugins={[remarkGfm]}
      components={{
        img: (props: React.ComponentPropsWithoutRef<'img'>) => <ImageDispatcher {...props} />,
        code: (
          props: React.ComponentPropsWithoutRef<'code'> & { node?: unknown }
        ) => {
          const { className, children, node, ...rest } = props;
          const match = /language-(\S+)/.exec(className ?? '');
          const lang = match?.[1];
          const isBlock =
            match !== null || (typeof children === 'string' && String(children).includes('\n'));

          // Inline Plotly chart path: `\`\`\`plotly-json` fence renders
          // directly via PlotlyChart with the JSON string in memory. No
          // network fetch, no signed-URL TTL.
          if (isBlock && lang === 'plotly-json') {
            const raw = extractCodeText(children, node).trim();
            if (raw.length === 0) {
              return (
                <div
                  className="my-3 rounded-lg border border-amber-500/30 bg-amber-500/5 p-3 text-sm text-amber-300"
                  role="alert"
                >
                  Chart payload was empty.
                </div>
              );
            }
            return <PlotlyChart inlineJson={raw} />;
          }

          if (isBlock) {
            return (
              <CodeBlock language={lang} {...rest}>
                {children}
              </CodeBlock>
            );
          }
          return (
            <code
              className="rounded bg-white/[0.06] px-1 py-0.5 font-mono text-[0.875em] text-foreground/90"
              {...rest}
            >
              {children}
            </code>
          );
        },
      }}
    >
      {text}
    </ReactMarkdown>
  );
}
