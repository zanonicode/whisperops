import logging
import os

from opentelemetry import trace
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor


def _configure_tracer() -> trace.Tracer:
    otlp_endpoint = os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://otel-collector.observability:4317")
    resource = Resource.create(
        {
            "service.name": "sandbox",
            "service.version": "0.1.0",
        }
    )
    provider = TracerProvider(resource=resource)
    exporter = OTLPSpanExporter(endpoint=otlp_endpoint, insecure=True)
    provider.add_span_processor(BatchSpanProcessor(exporter))
    trace.set_tracer_provider(provider)
    return trace.get_tracer("sandbox")


def _configure_logger() -> logging.Logger:
    logging.basicConfig(
        format='{"time": "%(asctime)s", "level": "%(levelname)s", "message": "%(message)s", "logger": "%(name)s"}',
        level=logging.INFO,
    )
    return logging.getLogger("sandbox")


tracer = _configure_tracer()
logger = _configure_logger()
