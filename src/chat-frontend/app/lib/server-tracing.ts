import { trace, context, propagation, type Span } from '@opentelemetry/api';

const tracer = trace.getTracer('chat-frontend', '0.1.0');

export function startChatSpan(name: string): Span {
  return tracer.startSpan(name);
}

export function extractTraceparent(span: Span): string | null {
  const carrier: Record<string, string> = {};
  propagation.inject(trace.setSpan(context.active(), span), carrier);
  return carrier['traceparent'] ?? null;
}

export { tracer };
