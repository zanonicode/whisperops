'use client';

import ReactMarkdown from 'react-markdown';
import remarkGfm from 'remark-gfm';
import { ImageDispatcher } from '@/lib/markdown';
import { CodeBlock } from './CodeBlock';

interface MarkdownContentProps {
  text: string;
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
          const { className, children, node: _node, ...rest } = props;
          const match = /language-(\w+)/.exec(className ?? '');
          const isBlock =
            match !== null || (typeof children === 'string' && String(children).includes('\n'));
          if (isBlock) {
            return (
              <CodeBlock language={match?.[1]} {...rest}>
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
