/**
 * Server-side OTel tracer for the Next.js route handlers.
 * Browser-side tracing lives in `observability.ts`; this is the Node SDK.
 *
 * Initialized lazily on first import. Ships traces to the cluster's OTel
 * Collector via OTLP/HTTP at OTEL_EXPORTER_OTLP_ENDPOINT (default
 * http://otel-collector.observability:4318).
 */

import { NodeTracerProvider } from '@opentelemetry/sdk-trace-node';
import { BatchSpanProcessor } from '@opentelemetry/sdk-trace-base';
import { OTLPTraceExporter } from '@opentelemetry/exporter-trace-otlp-http';
import { Resource } from '@opentelemetry/resources';
import { ATTR_SERVICE_NAME, ATTR_SERVICE_VERSION } from '@opentelemetry/semantic-conventions';
import { trace, type Tracer } from '@opentelemetry/api';

let initialized = false;

function init(): void {
  if (initialized) return;
  initialized = true;

  const endpoint =
    process.env.OTEL_EXPORTER_OTLP_ENDPOINT ?? 'http://otel-collector.observability:4318';

  const resource = new Resource({
    [ATTR_SERVICE_NAME]: 'chat-frontend',
    [ATTR_SERVICE_VERSION]: '0.1.0',
  });

  const exporter = new OTLPTraceExporter({
    url: `${endpoint}/v1/traces`,
  });

  const provider = new NodeTracerProvider({
    resource,
    spanProcessors: [new BatchSpanProcessor(exporter)],
  });

  provider.register();
}

export function getServerTracer(): Tracer {
  init();
  return trace.getTracer('chat-frontend.server');
}
