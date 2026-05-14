export interface AppEnv {
  PLANNER_URL: string;
  STREAMING_ENABLED: string;
  AGENT_NAME: string;
}

export function getEnv(): AppEnv {
  const plannerUrl = process.env.PLANNER_URL;
  if (!plannerUrl) {
    throw new Error(
      'PLANNER_URL environment variable is not set. ' +
        'Each chat-frontend Deployment must have PLANNER_URL pointing to its planner service.'
    );
  }
  return {
    PLANNER_URL: plannerUrl,
    STREAMING_ENABLED: process.env.STREAMING_ENABLED ?? 'true',
    AGENT_NAME: process.env.AGENT_NAME ?? 'unknown',
  };
}
