> **Superseded.** See [docs/OPERATIONS.md §3](OPERATIONS.md#3--observability-navigation) for the current canonical observability guide.
> The content below is preserved for historical context; some details may be stale post-DESIGN v1.4 (Langfuse Cloud activation in DD-24/v1.6, tempo-mono in DD-21/DD-30, budget-controller in DD-28).

# Observability

## Grafana Dashboards

All dashboards are provisioned via the `observability-extras` Helm chart in the `whisperops` Grafana folder.

| Dashboard | UID | Key Panels |
|-----------|-----|-----------|
| Platform Health | `whisperops-platform-health` | Cluster CPU/memory, ArgoCD sync count, cert expiry, NGINX p50/p95/p99 |
| Agent Cost | `whisperops-agent-cost` | Total LLM spend, max budget burn, top-10 agents by cost |
| Agent Performance | `whisperops-agent-performance` | Query latency p50/p95/p99, A2A hop breakdown, error rate by type |
| Sandbox Execution | `whisperops-sandbox-execution` | Concurrent execs, timeout rate, OOM rate, upload latency |

## Trace Architecture

All spans flow through OTel Collector → fan-out to:
- **Tempo** (in-cluster): trace search, service map, span drill-down
- **Langfuse Cloud**: LLM cost tracking, prompt/response logging, session replay

### Key Span Names

| Service | Span | Key Attributes |
|---------|------|---------------|
| sandbox | `sandbox.execute` | `agent.id`, `dataset.id`, `execution.exit_code`, `execution.error` |
| chat-frontend | `chat.sse_stream` | `agent_id`, `response_tokens` |

## Alert Rules

Alerts are defined in `platform/observability/alerts/`:

### platform-slos.yaml
- `WhisperopsQueryLatencySLOBurnFast` (critical): 14.4× error budget burn rate over 1h
- `WhisperopsQueryLatencySLOBurnSlow` (warning): 6× error budget burn rate over 6h
- `SandboxHighTimeoutRate` (warning): >10% of executions timeout over 5m
- `SandboxOOMsDetected` (warning): any OOM events over 5m

### budget-burn.yaml
- `AgentBudget80Percent` (warning): agent at 80-99% of configured budget
- `AgentBudget100Percent` (critical): agent budget exhausted, scaled to 0
- `AgentBudgetControllerDown` (critical): budget-controller absent for 5m

## Querying Traces

In Grafana → Tempo datasource:

```
{resource.service.name="sandbox"} | duration > 10s
```

Find slow executions:
```
{resource.service.name="sandbox", execution.exit_code="-1"}
```

## Langfuse Cost Queries

Langfuse Cloud (https://cloud.langfuse.com) provides:
- Per-agent session cost breakdown
- Model comparison (Haiku vs Sonnet cost per query)
- Prompt token usage trends

Traces are tagged with `agent-{name}-{suffix}` and `dataset:{dataset_id}` via OTel tags in the kagent Agent CRD.

## Adding Custom Metrics

To add a metric from a new service:
1. Instrument with OTel SDK (Python: `opentelemetry-sdk`, TypeScript: `@opentelemetry/sdk-trace-web`)
2. Export to `http://otel-collector.observability:4317` (gRPC) or `:4318` (HTTP)
3. Add recording rules and dashboards to `platform/helm/observability-extras/`
4. Add alert rules to `platform/observability/alerts/`
