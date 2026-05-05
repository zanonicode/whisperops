'use client';

import { useState, useRef, useEffect } from 'react';
import Message from './components/Message';
import { createSSEConnection } from '../lib/sse';

interface ChatMessage {
  id: string;
  role: 'user' | 'assistant';
  content: string;
  chartUrls?: string[];
  codeBlocks?: string[];
}

export default function ChatPage() {
  const [messages, setMessages] = useState<ChatMessage[]>([]);
  const [input, setInput] = useState('');
  const [isStreaming, setIsStreaming] = useState(false);
  const [darkMode, setDarkMode] = useState(false);
  const messagesEndRef = useRef<HTMLDivElement>(null);
  const abortRef = useRef<(() => void) | null>(null);

  useEffect(() => {
    messagesEndRef.current?.scrollIntoView({ behavior: 'smooth' });
  }, [messages]);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!input.trim() || isStreaming) return;

    const userMessage: ChatMessage = {
      id: crypto.randomUUID(),
      role: 'user',
      content: input.trim(),
    };

    setMessages((prev) => [...prev, userMessage]);
    setInput('');
    setIsStreaming(true);

    const assistantMessageId = crypto.randomUUID();
    setMessages((prev) => [
      ...prev,
      { id: assistantMessageId, role: 'assistant', content: '' },
    ]);

    const { abort } = createSSEConnection({
      url: '/api/chat',
      body: { message: userMessage.content },
      onChunk: (chunk) => {
        setMessages((prev) =>
          prev.map((m) =>
            m.id === assistantMessageId
              ? { ...m, content: m.content + chunk }
              : m
          )
        );
      },
      onDone: () => {
        setIsStreaming(false);
        abortRef.current = null;
      },
      onError: (err) => {
        console.error('SSE error:', err);
        setIsStreaming(false);
        abortRef.current = null;
      },
    });

    abortRef.current = abort;
  };

  const handleStop = () => {
    abortRef.current?.();
    setIsStreaming(false);
  };

  return (
    <div className={darkMode ? 'dark' : ''}>
      <div className="flex flex-col h-screen bg-white dark:bg-gray-900 text-gray-900 dark:text-gray-100">
        <header className="flex items-center justify-between px-6 py-4 border-b border-gray-200 dark:border-gray-700">
          <div>
            <h1 className="text-xl font-semibold">Dataset Whisperer</h1>
            <p className="text-sm text-gray-500 dark:text-gray-400">
              Agent: {process.env.NEXT_PUBLIC_AGENT_ID ?? 'unknown'}
            </p>
          </div>
          <button
            onClick={() => setDarkMode((d) => !d)}
            className="px-3 py-1 rounded text-sm border border-gray-300 dark:border-gray-600 hover:bg-gray-100 dark:hover:bg-gray-800"
          >
            {darkMode ? 'Light' : 'Dark'}
          </button>
        </header>

        <main className="flex-1 overflow-y-auto px-4 py-6 space-y-4 max-w-4xl mx-auto w-full">
          {messages.length === 0 && (
            <div className="text-center text-gray-400 mt-20">
              <p className="text-lg">Ask a question about your dataset.</p>
              <p className="text-sm mt-2">
                Try: &quot;What is the distribution of prices?&quot; or &quot;Show me the top 10 categories.&quot;
              </p>
            </div>
          )}
          {messages.map((msg) => (
            <Message key={msg.id} message={msg} />
          ))}
          <div ref={messagesEndRef} />
        </main>

        <footer className="border-t border-gray-200 dark:border-gray-700 px-4 py-4">
          <form
            onSubmit={handleSubmit}
            className="flex gap-3 max-w-4xl mx-auto"
          >
            <input
              type="text"
              value={input}
              onChange={(e) => setInput(e.target.value)}
              disabled={isStreaming}
              placeholder="Ask a question about your dataset..."
              className="flex-1 px-4 py-2 rounded-lg border border-gray-300 dark:border-gray-600 bg-white dark:bg-gray-800 focus:outline-none focus:ring-2 focus:ring-blue-500 disabled:opacity-50"
            />
            {isStreaming ? (
              <button
                type="button"
                onClick={handleStop}
                className="px-4 py-2 rounded-lg bg-red-500 text-white hover:bg-red-600"
              >
                Stop
              </button>
            ) : (
              <button
                type="submit"
                disabled={!input.trim()}
                className="px-4 py-2 rounded-lg bg-blue-600 text-white hover:bg-blue-700 disabled:opacity-50"
              >
                Send
              </button>
            )}
          </form>
        </footer>
      </div>
    </div>
  );
}
