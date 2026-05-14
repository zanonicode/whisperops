import { describe, it, expect, vi, afterEach } from 'vitest';

vi.mock('@/lib/kagent/agentCard', () => ({
  fetchAgentCard: vi.fn(),
}));

const mockCard = {
  name: 'Test Agent',
  description: 'A test agent',
  version: '0.1.0',
  url: 'http://planner.test:8083',
};

describe('GET /api/agent-card', () => {
  afterEach(() => {
    vi.clearAllMocks();
  });

  it('proxies the agent card from planner', async () => {
    const { fetchAgentCard } = await import('@/lib/kagent/agentCard');
    vi.mocked(fetchAgentCard).mockResolvedValue(mockCard as never);

    vi.stubEnv('PLANNER_URL', 'http://planner.test:8083');
    const { GET } = await import('@/api/agent-card/route');
    const res = await GET();
    const data = await res.json();
    expect(data.name).toBe('Test Agent');
    vi.unstubAllEnvs();
  });

  it('returns 503 when PLANNER_URL is not set', async () => {
    vi.stubEnv('PLANNER_URL', '');
    const { GET } = await import('@/api/agent-card/route');
    const res = await GET();
    expect(res.status).toBe(503);
    vi.unstubAllEnvs();
  });

  it('returns 502 when fetchAgentCard throws', async () => {
    const { fetchAgentCard } = await import('@/lib/kagent/agentCard');
    vi.mocked(fetchAgentCard).mockRejectedValue(new Error('ECONNREFUSED'));

    vi.stubEnv('PLANNER_URL', 'http://planner.test:8083');
    const { GET } = await import('@/api/agent-card/route');
    const res = await GET();
    expect(res.status).toBe(502);
    vi.unstubAllEnvs();
  });
});
