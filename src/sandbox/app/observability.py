import logging
import os

from opentelemetry import metrics, trace
from opentelemetry.exporter.otlp.proto.grpc.metric_exporter import OTLPMetricExporter
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.sdk.metrics import MeterProvider
from opentelemetry.sdk.metrics.export import PeriodicExportingMetricReader
from opentelemetry.sdk.metrics.view import ExplicitBucketHistogramAggregation, View
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor


def _otlp_endpoint() -> str:
    return os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://otel-collector.observability:4317")


def _resource() -> Resource:
    return Resource.create(
        {
            "service.name": "sandbox",
            "service.version": "0.1.0",
        }
    )


def _configure_tracer() -> trace.Tracer:
    provider = TracerProvider(resource=_resource())
    exporter = OTLPSpanExporter(endpoint=_otlp_endpoint(), insecure=True)
    provider.add_span_processor(BatchSpanProcessor(exporter))
    trace.set_tracer_provider(provider)
    return trace.get_tracer("sandbox")


def _configure_meter() -> metrics.Meter:
    reader = PeriodicExportingMetricReader(
        OTLPMetricExporter(endpoint=_otlp_endpoint(), insecure=True),
        export_interval_millis=30_000,
    )
    duration_view = View(
        instrument_name="sandbox.execution.duration",
        aggregation=ExplicitBucketHistogramAggregation(
            boundaries=(1, 5, 10, 30, 60, 120, 300, 600),
        ),
    )
    provider = MeterProvider(resource=_resource(), metric_readers=[reader], views=[duration_view])
    metrics.set_meter_provider(provider)
    return metrics.get_meter("sandbox")


def _configure_logger() -> logging.Logger:
    logging.basicConfig(
        format='{"time": "%(asctime)s", "level": "%(levelname)s", "message": "%(message)s", "logger": "%(name)s"}',
        level=logging.INFO,
    )
    return logging.getLogger("sandbox")


tracer = _configure_tracer()
meter = _configure_meter()
logger = _configure_logger()

sandbox_executions = meter.create_counter(
    "sandbox.executions",
    description="Sandbox executions by outcome (success|error)",
)
sandbox_oom = meter.create_counter(
    "sandbox.oom",
    description="Sandbox executions terminated by OOM (exit code 137 or -9 heuristic)",
)
sandbox_timeouts = meter.create_counter(
    "sandbox.timeouts",
    description="Sandbox executions terminated by subprocess timeout",
)
sandbox_duration = meter.create_histogram(
    "sandbox.execution.duration",
    unit="s",
    description="Sandbox execution wall-clock duration in seconds",
)
