import { metrics } from '@opentelemetry/api';

const meter = metrics.getMeter('chat-frontend', '0.1.0');

export const httpRequestsTotal = meter.createCounter('http_requests_total', {
  description: 'Total number of HTTP requests handled by the route layer',
  unit: '{request}',
});

export const ttftHistogram = meter.createHistogram('chat_frontend_ttft_seconds', {
  description: 'Time to first token from the planner SSE stream',
  unit: 's',
});

export const e2eHistogram = meter.createHistogram('chat_frontend_e2e_seconds', {
  description: 'End-to-end time from request received to terminal event',
  unit: 's',
});

export const tokensInputTotal = meter.createCounter('whisperops_tokens_input_total', {
  description: 'Total input tokens reported by kagent usage metadata',
  unit: '{token}',
});

export const tokensOutputTotal = meter.createCounter('whisperops_tokens_output_total', {
  description: 'Total output tokens reported by kagent usage metadata',
  unit: '{token}',
});

export const tokensCachedInputTotal = meter.createCounter('whisperops_tokens_cached_input_total', {
  description: 'Total cached input tokens reported by kagent usage metadata',
  unit: '{token}',
});

export const streamRetriesTotal = meter.createCounter('chat_frontend_stream_retries_total', {
  description: 'Transparent one-shot retries triggered by retryable stream errors (e.g. stream closed without terminal signal). Each increment corresponds to one user turn whose first attempt failed and was silently re-sent.',
  unit: '{retry}',
});
