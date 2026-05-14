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
OTEL_ENDPOINT = os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://otel-collector.observability:4317")
MIMIR_URL = os.getenv(
    "MIMIR_URL",
    "http://lgtm-distributed-mimir-nginx.observability.svc:80/prometheus/api/v1",
)


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


def poll_killswitch_alerts() -> list[dict]:
    """Return list of firing BudgetBurnPage alerts from the Mimir ruler API.

    Each entry has: agent_name, namespace, spend_usd, budget_usd.
    Replaces the Langfuse REST poll (ADR-Obs-14): Mimir is in-cluster with no
    external dependency; the firing state reflects the recording-rule math in
    budget-burn.yaml, not a live Langfuse API call.
    """
    with httpx.Client(timeout=10) as http:
        response = http.get(f"{MIMIR_URL}/alerts")
        response.raise_for_status()
        payload = response.json()

    out = []
    for alert in payload.get("data", {}).get("alerts", []):
        if alert.get("state") != "firing":
            continue
        if alert.get("labels", {}).get("action") != "killswitch":
            continue
        labels = alert["labels"]
        out.append({
            "agent_name": labels.get("agent_name"),
            "namespace": labels.get("namespace"),
            "alertname": labels.get("alertname"),
            "spend_usd": float(alert.get("annotations", {}).get("spend_usd", 0)),
            "budget_usd": float(alert.get("annotations", {}).get("budget_usd", 0)),
        })
    return out


def _build_budget_gauge_callbacks(agents: list[dict]):
    def budget_callbacks(options):
        return [
            metrics.Observation(
                float(a.get("budget_usd", 0)),
                {
                    "agent_name": a["agent_name"],
                    "namespace": a["namespace"],
                },
            )
            for a in agents
            if a.get("agent_name")
        ]
    return budget_callbacks


def list_agent_crds(api: k8s_client.CustomObjectsApi) -> list[dict]:
    result = api.list_cluster_custom_object(
        group="kagent.dev",
        version="v1alpha1",
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
            api_version="kagent.dev/v1alpha1",
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
    budget_gauge: metrics.ObservableGauge | None,
) -> None:
    agents = list_agent_crds(custom_api)

    agent_budgets = []
    for agent in agents:
        agent_name = agent["metadata"]["name"]
        namespace = agent["metadata"]["namespace"]
        budget_usd = get_budget_usd(agent)
        if budget_usd is not None:
            agent_budgets.append({
                "agent_name": agent_name,
                "namespace": namespace,
                "budget_usd": budget_usd,
            })

    try:
        firing_alerts = poll_killswitch_alerts()
    except Exception as exc:
        logger.warning("Failed to poll Mimir alerts: %s", exc)
        firing_alerts = []

    for alert in firing_alerts:
        agent_name = alert["agent_name"]
        namespace = alert["namespace"]

        with tracer.start_as_current_span("budget_controller.evaluate_alert") as span:
            span.set_attribute("agent_name", agent_name or "")
            span.set_attribute("namespace", namespace or "")
            span.set_attribute("alertname", alert.get("alertname", ""))
            span.set_attribute("spend_usd", alert["spend_usd"])
            span.set_attribute("budget_usd", alert["budget_usd"])

            logger.warning(
                "Budget exhausted: agent=%s namespace=%s spend=%.4f budget=%.4f",
                agent_name,
                namespace,
                alert["spend_usd"],
                alert["budget_usd"],
            )

            try:
                emit_warning_event(
                    core_api,
                    namespace,
                    agent_name,
                    f"BudgetExhausted: ${alert['spend_usd']:.4f} / ${alert['budget_usd']:.4f}",
                )
            except Exception as exc:
                logger.warning("Failed to emit BudgetExhausted event for %s/%s: %s", namespace, agent_name, exc)

            with tracer.start_as_current_span("budget_controller.killswitch") as ks_span:
                ks_span.set_attribute("agent_name", agent_name or "")
                ks_span.set_attribute("namespace", namespace or "")
                try:
                    scale_deployments_to_zero(apps_api, namespace)
                except Exception as exc:
                    logger.error("Failed to scale %s to zero: %s", namespace, exc)
                    ks_span.record_exception(exc)


def main() -> None:
    try:
        k8s_config.load_incluster_config()
    except k8s_config.ConfigException:
        k8s_config.load_kube_config()

    custom_api = k8s_client.CustomObjectsApi()
    apps_api = k8s_client.AppsV1Api()
    core_api = k8s_client.CoreV1Api()

    budget_gauge = meter.create_observable_gauge(
        "whisperops.agent.budget.usd",
        description="Per-agent USD budget from Agent CR whisperops.io/budget-usd annotation",
    )

    logger.info("Budget controller started (Mimir PromQL mode), polling every %ds", POLL_INTERVAL_S)

    while True:
        with tracer.start_as_current_span("budget_controller.run_once") as span:
            span.set_attribute("gen_ai.provider.name", "gcp.vertex_ai")
            span.set_attribute("gen_ai.system", "gcp.vertex_ai")
            span.set_attribute("gen_ai.request.model", "gemini-2.5-flash")
            try:
                run_once(custom_api, apps_api, core_api, budget_gauge)
            except Exception as exc:
                logger.error("Poll cycle failed: %s", exc, exc_info=True)
        time.sleep(POLL_INTERVAL_S)


if __name__ == "__main__":
    main()
