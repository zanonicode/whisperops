import { WebTracerProvider } from '@opentelemetry/sdk-trace-web';
import { OTLPTraceExporter } from '@opentelemetry/exporter-trace-otlp-http';
import { BatchSpanProcessor } from '@opentelemetry/sdk-trace-base';
import { Resource } from '@opentelemetry/resources';
import { ATTR_SERVICE_NAME } from '@opentelemetry/semantic-conventions';
import { trace } from '@opentelemetry/api';

let initialized = false;

export function initObservability(): void {
  if (initialized || typeof window === 'undefined') return;
  initialized = true;

  const otlpEndpoint =
    process.env.NEXT_PUBLIC_OTEL_ENDPOINT ?? 'http://otel-collector.observability:4318';

  const resource = new Resource({
    [ATTR_SERVICE_NAME]: 'chat-frontend',
  });

  const exporter = new OTLPTraceExporter({
    url: `${otlpEndpoint}/v1/traces`,
    headers: {},
  });

  const provider = new WebTracerProvider({
    resource,
    spanProcessors: [new BatchSpanProcessor(exporter)],
  });

  provider.register();
}

export function getTracer() {
  return trace.getTracer('chat-frontend');
}
