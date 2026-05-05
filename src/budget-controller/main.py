import logging
import os
import time

import httpx
from kubernetes import client as k8s_client
from kubernetes import config as k8s_config
from opentelemetry import metrics, trace
from opentelemetry.exporter.otlp.proto.grpc.metric_exporter import OTLPMetricExporter
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.sdk.metrics import MeterProvider
from opentelemetry.sdk.metrics.export import PeriodicExportingMetricReader
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor

logging.basicConfig(
    format='{"time": "%(asctime)s", "level": "%(levelname)s", "message": "%(message)s"}',
    level=logging.INFO,
)
logger = logging.getLogger("budget-controller")

POLL_INTERVAL_S = int(os.getenv("POLL_INTERVAL_S", "60"))
LANGFUSE_HOST = os.getenv("LANGFUSE_HOST", "https://cloud.langfuse.com")
LANGFUSE_PUBLIC_KEY = os.environ["LANGFUSE_PUBLIC_KEY"]
LANGFUSE_SECRET_KEY = os.environ["LANGFUSE_SECRET_KEY"]
OTEL_ENDPOINT = os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://otel-collector.observability:4317")


def _setup_telemetry() -> tuple[trace.Tracer, metrics.Meter]:
    resource = Resource.create({"service.name": "budget-controller"})

    trace_provider = TracerProvider(resource=resource)
    trace_provider.add_span_processor(
        BatchSpanProcessor(OTLPSpanExporter(endpoint=OTEL_ENDPOINT, insecure=True))
    )
    trace.set_tracer_provider(trace_provider)

    metric_reader = PeriodicExportingMetricReader(
        OTLPMetricExporter(endpoint=OTEL_ENDPOINT, insecure=True),
        export_interval_millis=30_000,
    )
    meter_provider = MeterProvider(resource=resource, metric_readers=[metric_reader])
    metrics.set_meter_provider(meter_provider)

    return trace.get_tracer("budget-controller"), metrics.get_meter("budget-controller")


tracer, meter = _setup_telemetry()
budget_80_counter = meter.create_counter(
    "whisperops.budget.80pct",
    description="Agents that hit 80% budget threshold",
)
budget_100_counter = meter.create_counter(
    "whisperops.budget.100pct",
    description="Agents that hit 100% budget threshold (scaled to 0)",
)


def get_langfuse_spend(agent_id: str) -> float:
    with httpx.Client(timeout=10) as http:
        response = http.get(
            f"{LANGFUSE_HOST}/api/public/metrics/usage",
            auth=(LANGFUSE_PUBLIC_KEY, LANGFUSE_SECRET_KEY),
            params={"agentId": agent_id, "window": "30d"},
        )
        response.raise_for_status()
        data = response.json()
        return float(data.get("totalCost", 0.0))


def list_agent_crds(api: k8s_client.CustomObjectsApi) -> list[dict]:
    result = api.list_cluster_custom_object(
        group="kagent.dev",
        version="v1",
        plural="agents",
    )
    return result.get("items", [])


def get_budget_usd(agent: dict) -> float | None:
    annotations = agent.get("metadata", {}).get("annotations", {})
    budget_str = annotations.get("whisperops.io/budget-usd")
    if budget_str is None:
        return None
    try:
        return float(budget_str)
    except ValueError:
        return None


def scale_deployments_to_zero(apps_api: k8s_client.AppsV1Api, namespace: str) -> None:
    deployments = apps_api.list_namespaced_deployment(namespace=namespace)
    for dep in deployments.items:
        if dep.spec.replicas != 0:
            apps_api.patch_namespaced_deployment(
                name=dep.metadata.name,
                namespace=namespace,
                body={"spec": {"replicas": 0}},
            )
            logger.info("Scaled %s/%s to 0 replicas", namespace, dep.metadata.name)


def emit_warning_event(
    core_api: k8s_client.CoreV1Api,
    namespace: str,
    agent_name: str,
    message: str,
) -> None:
    event = k8s_client.CoreV1Event(
        metadata=k8s_client.V1ObjectMeta(
            name=f"budget-warning-{agent_name}-{int(time.time())}",
            namespace=namespace,
        ),
        involved_object=k8s_client.V1ObjectReference(
            kind="Agent",
            api_version="kagent.dev/v1",
            name=agent_name,
            namespace=namespace,
        ),
        reason="BudgetThreshold",
        message=message,
        type="Warning",
        event_time=None,
        first_timestamp=None,
        last_timestamp=None,
        reporting_component="budget-controller",
        reporting_instance="budget-controller",
        action="BudgetEnforcement",
        count=1,
        source=k8s_client.V1EventSource(component="budget-controller"),
    )
    core_api.create_namespaced_event(namespace=namespace, body=event)


def run_once(
    custom_api: k8s_client.CustomObjectsApi,
    apps_api: k8s_client.AppsV1Api,
    core_api: k8s_client.CoreV1Api,
) -> None:
    agents = list_agent_crds(custom_api)
    for agent in agents:
        agent_name = agent["metadata"]["name"]
        namespace = agent["metadata"]["namespace"]
        budget_usd = get_budget_usd(agent)

        if budget_usd is None:
            continue

        try:
            spend = get_langfuse_spend(agent_id=f"{namespace}/{agent_name}")
        except Exception as exc:
            logger.warning("Failed to fetch spend for %s/%s: %s", namespace, agent_name, exc)
            continue

        ratio = spend / budget_usd if budget_usd > 0 else 0.0
        attrs = {"agent_namespace": namespace, "agent_name": agent_name}

        if ratio >= 1.0:
            logger.warning("Agent %s/%s exhausted budget (%.2f/%.2f)", namespace, agent_name, spend, budget_usd)
            budget_100_counter.add(1, attrs)
            try:
                emit_warning_event(core_api, namespace, agent_name, f"Budget exhausted: ${spend:.2f} / ${budget_usd:.2f}")
                scale_deployments_to_zero(apps_api, namespace)
            except Exception as exc:
                logger.error("Failed to enforce 100%% budget for %s/%s: %s", namespace, agent_name, exc)
        elif ratio >= 0.8:
            logger.info("Agent %s/%s at 80%% budget (%.2f/%.2f)", namespace, agent_name, spend, budget_usd)
            budget_80_counter.add(1, attrs)
            try:
                emit_warning_event(core_api, namespace, agent_name, f"Budget 80%%: ${spend:.2f} / ${budget_usd:.2f}")
            except Exception as exc:
                logger.warning("Failed to emit 80%% event for %s/%s: %s", namespace, agent_name, exc)


def main() -> None:
    try:
        k8s_config.load_incluster_config()
    except k8s_config.ConfigException:
        k8s_config.load_kube_config()

    custom_api = k8s_client.CustomObjectsApi()
    apps_api = k8s_client.AppsV1Api()
    core_api = k8s_client.CoreV1Api()

    logger.info("Budget controller started, polling every %ds", POLL_INTERVAL_S)

    while True:
        with tracer.start_as_current_span("budget_controller.run_once"):
            try:
                run_once(custom_api, apps_api, core_api)
            except Exception as exc:
                logger.error("Poll cycle failed: %s", exc, exc_info=True)
        time.sleep(POLL_INTERVAL_S)


if __name__ == "__main__":
    main()
