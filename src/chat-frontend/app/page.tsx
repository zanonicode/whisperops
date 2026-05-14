import { SkipToContent } from './components/SkipToContent';
import { ChatPageClient } from './components/ChatPageClient';

export const dynamic = 'force-dynamic';

export default function ChatPage() {
  const agentName = process.env.AGENT_NAME ?? 'unknown';

  return (
    <>
      <SkipToContent />
      <ChatPageClient agentName={agentName} />
    </>
  );
}
