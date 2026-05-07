import ChatPageClient from './components/ChatPageClient';

export default function ChatPage() {
  const agentNamespace = process.env.AGENT_NAMESPACE ?? 'unknown';
  const agentName = process.env.AGENT_NAME;

  return <ChatPageClient agentNamespace={agentNamespace} agentName={agentName} />;
}
