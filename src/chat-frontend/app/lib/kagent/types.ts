export interface MessagePart {
  kind: 'text' | 'data' | 'file';
  text?: string;
  data?: Record<string, unknown>;
  metadata?: {
    kagent_type?: 'function_call' | 'function_response';
    [key: string]: unknown;
  };
}

export interface TaskStatus {
  state: 'submitted' | 'working' | 'completed' | 'input-required' | 'canceled' | 'failed';
  message?: {
    role: 'user' | 'agent';
    parts: MessagePart[];
  };
}

export interface KagentUsageMetadata {
  candidatesTokenCount?: number;
  promptTokenCount?: number;
  thoughtsTokenCount?: number;
  totalTokenCount?: number;
  cachedTokenCount?: number;
}

export interface EventMetadata {
  kagent_author?: 'planner' | 'worker' | string;
  kagent_usage_metadata?: KagentUsageMetadata;
  kagent_app_name?: string;
  kagent_session_id?: string;
  kagent_invocation_id?: string;
  kagent_adk_partial?: boolean | null;
}

export interface StatusUpdate {
  kind: 'status-update';
  contextId: string;
  taskId: string;
  final: boolean;
  status: TaskStatus;
  metadata?: EventMetadata;
}

export interface ArtifactUpdate {
  kind: 'artifact-update';
  contextId: string;
  taskId: string;
  lastChunk: boolean;
  artifact: {
    artifactId: string;
    parts: MessagePart[];
  };
  metadata?: EventMetadata;
}

export interface JsonRpcEnvelope {
  jsonrpc: '2.0';
  id: number;
  result?: StatusUpdate | ArtifactUpdate;
  error?: {
    code: number;
    message: string;
    data?: unknown;
  };
}

export type AnyKagentEvent = StatusUpdate | ArtifactUpdate;

export interface AgentSkill {
  id: string;
  name: string;
  description?: string;
  examples?: string[];
}

export interface AgentCapabilities {
  streaming?: boolean;
  pushNotifications?: boolean;
  stateTransitionHistory?: boolean;
}

export interface AgentCard {
  name: string;
  description: string;
  version?: string;
  url?: string;
  capabilities?: AgentCapabilities;
  skills?: AgentSkill[];
}

export type NormalizedEventType =
  | { type: 'submitted' }
  | { type: 'text'; text: string; author?: string }
  | { type: 'author'; author: string }
  | { type: 'artifact'; text: string }
  | { type: 'terminal'; reason: 'final' | 'lastChunk' | 'failed' }
  | { type: 'usage'; usage: KagentUsageMetadata }
  | { type: 'error'; message: string };

export type NormalizedEvent = NormalizedEventType;
