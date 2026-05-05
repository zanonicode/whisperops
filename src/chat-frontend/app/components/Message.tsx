import ChartEmbed from './ChartEmbed';
import CodeBlock from './CodeBlock';

interface ChatMessage {
  id: string;
  role: 'user' | 'assistant';
  content: string;
  chartUrls?: string[];
  codeBlocks?: string[];
}

interface MessageProps {
  message: ChatMessage;
}

function extractChartUrls(content: string): string[] {
  const urls: string[] = [];
  const imgRegex = /!\[.*?\]\((https?:\/\/[^\s)]+)\)/g;
  const linkRegex = /\[Interactive Chart\]\((https?:\/\/[^\s)]+)\)/g;
  let match;

  while ((match = imgRegex.exec(content)) !== null) {
    urls.push(match[1]);
  }
  while ((match = linkRegex.exec(content)) !== null) {
    urls.push(match[1]);
  }
  return urls;
}

function extractCodeBlocks(content: string): Array<{ code: string; language: string }> {
  const blocks: Array<{ code: string; language: string }> = [];
  const regex = /```(\w+)?\n([\s\S]*?)```/g;
  let match;

  while ((match = regex.exec(content)) !== null) {
    blocks.push({ language: match[1] ?? 'text', code: match[2] });
  }
  return blocks;
}

function renderMarkdownContent(content: string): React.ReactNode {
  const chartUrls = extractChartUrls(content);
  const codeBlocks = extractCodeBlocks(content);

  let processed = content;
  processed = processed.replace(/!\[.*?\]\(https?:\/\/[^\s)]+\)/g, '');
  processed = processed.replace(/\[Interactive Chart\]\(https?:\/\/[^\s)]+\)/g, '');
  processed = processed.replace(/```(\w+)?\n[\s\S]*?```/g, '');

  const lines = processed.split('\n').filter((l) => l.trim() !== '');

  return (
    <>
      {lines.map((line, i) => (
        <p key={i} className="mb-2 leading-relaxed">
          {line}
        </p>
      ))}
      {chartUrls.map((url, i) => (
        <ChartEmbed key={`chart-${i}`} url={url} alt={`Chart ${i + 1}`} />
      ))}
      {codeBlocks.map((block, i) => (
        <CodeBlock key={`code-${i}`} code={block.code} language={block.language} />
      ))}
    </>
  );
}

export default function Message({ message }: MessageProps) {
  const isUser = message.role === 'user';

  return (
    <div className={`flex ${isUser ? 'justify-end' : 'justify-start'}`}>
      <div
        className={`max-w-3xl w-full rounded-2xl px-4 py-3 ${
          isUser
            ? 'bg-blue-600 text-white ml-12'
            : 'bg-gray-100 dark:bg-gray-800 text-gray-900 dark:text-gray-100 mr-12'
        }`}
      >
        {isUser ? (
          <p>{message.content}</p>
        ) : (
          <div className="prose dark:prose-invert max-w-none">
            {message.content ? (
              renderMarkdownContent(message.content)
            ) : (
              <span className="inline-block animate-pulse">...</span>
            )}
          </div>
        )}
      </div>
    </div>
  );
}
