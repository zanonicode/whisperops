import ChatPageClient from './components/ChatPageClient';

// Without this, Next.js prerenders / as Static (○) and bakes process.env into
// the HTML at build time — defeating the DD-44 runtime-config goal.
export const dynamic = 'force-dynamic';

export default function ChatPage() {
  const agentNamespace = process.env.AGENT_NAMESPACE ?? 'unknown';
  const agentName = process.env.AGENT_NAME;

  return <ChatPageClient agentNamespace={agentNamespace} agentName={agentName} />;
}
