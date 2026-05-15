# Runbook: SLO Burn Alert Triage

**Trigger:** `SLO_FastBurn` (severity: page) or `SLO_SlowBurn` (severity: warn) fires for a whisperops SLI.

**Severity:** P1 if page (fast-burn), P3 if warn (slow-burn)

---

## MWMBR alert definitions

| Alert | Burn rate | Time to exhaust budget | Window pair | Action |
|---|---|---|---|---|
| `SLO_FastBurn` | 14.4× | ~2 days | 5m + 1h both above threshold | Page — investigate immediately |
| `SLO_SlowBurn` | 6× | ~5 days | 30m + 6h both above threshold | Warn — file ticket, fix in hours |

---

## Triage checklist

### Step 1 — Identify which SLI is burning

```bash
alias kk='gcloud compute ssh whisperops-vm --zone=us-central1-a --command'

# List all firing SLO alerts
kk 'sudo kubectl exec -n observability deploy/lgtm-distributed-mimir-nginx -- \
  wget -qO- "http://localhost:80/prometheus/api/v1/alerts" \
  | python3 -m json.tool \
  | grep -E "\"alertname\"|\"agent_name\"|\"state\": \"firing\""'
```

The alert label `alertname` encodes the SLI tier. Common patterns:

| alertname | SLI | Symptom |
|---|---|---|
| `ChatFrontendAvailabilityFastBurn` | T1.1 — availability | chat-frontend returning 5xx |
| `ChatFrontendTTFTFastBurn` | T1.2 — TTFT p95 | first token latency > 10s |
| `ChatFrontendE2EFastBurn` | T1.3 — e2e latency | full response > 120s |
| `SandboxSuccessFastBurn` | T2.1 — sandbox | execute_python returning errors |
| `KagentA2ALatencyFastBurn` | A.1 — A2A latency | A2A calls > 30s p95 |

### Step 2 — Open the SLO Compliance dashboard

Grafana → Dashboards → platform/ → **SLO Compliance**.

The error budget burn-down panel shows the rate at which budget is consumed. A value of `14.4` means you are at the page-level burn rate. A horizontal threshold line at `1.0` = full budget exhausted.

### Step 3 — Correlate with RED metrics

Grafana → Dashboards → platform/ → **RED Method per Agent** → select the affected agent namespace.

Look for:
- **Rate spike**: sudden increase in requests (e.g. a load test or misconfigured retry loop)
- **Error spike**: error rate > threshold (5xx responses or sandbox exit codes != 0)
- **Duration spike**: latency p95 crossing the SLO threshold

### Step 4 — Trace a failing request

Grafana → Explore → Tempo.

```
# TraceQL: find error spans for a specific agent
{ resource.agent_name = "housing-demo" && status = error }

# TraceQL: find slow spans (duration > 30s A2A)
{ resource.agent_name = "housing-demo" && duration > 30s }
```

Click a trace → expand the span hierarchy → identify the failing component (planner, worker, sandbox).

### Step 5 — Follow trace→logs

From a failing span in Tempo, click **"Logs for this span"**. Grafana uses the `trace_id` Loki label (extracted by Alloy from JSON log bodies) to auto-generate a Loki query.

If the link produces no results, verify Alloy is running:

```bash
kk 'sudo kubectl get pods -n observability -l app.kubernetes.io/name=alloy'
# Expect 1/1 Running per node
```

### Step 6 — Common failure modes

| Symptom in traces | Root cause | Fix |
|---|---|---|
| `sandbox.mcp.execute_python` span timeout | Dataset too large for memory cap, or infinite loop in user code | Check sandbox OOM counter: `kk 'sudo kubectl top pod -n agent-{name}'`; raise memory limit or add timeout in code |
| A2A span returns immediately with error | kagent-controller unhealthy | `kk 'sudo kubectl logs -n kagent-system deploy/kagent-controller --tail=50'` |
| chat-frontend `/api/chat` 5xx | kagent session create failing | `kk 'sudo kubectl logs -n agent-{name} deploy/planner --tail=50'` |
| Vertex AI call returning 429/503 | Quota exceeded or regional outage | Check GCP Console → Vertex AI → Quotas; check `traces_spanmetrics_calls_total{service="vertex-ai",status_code="STATUS_CODE_ERROR"}` |

### Step 7 — Verify SLI recovery

After applying a fix, monitor the burn rate for two consecutive windows (5m + 1h for page-level). The `SLO_FastBurn` alert has a `for: 2m` hold; it should resolve within 2 minutes of the error rate dropping below the threshold.

```bash
# PromQL: current T1.1 availability SLI ratio (want > 0.99)
# In Grafana → Explore → Mimir:
#   sli:chat_frontend_availability:ratio_rate_5m
```

---

## When to escalate

- SLI ratio drops to 0 (complete outage) → move to incident-response.md
- Burn rate persists despite fix → check if recording rules are stale (Mimir Ruler eval failures in meta-observability dashboard)
- Alloy down → trace→logs join broken; use `{namespace=~"agent-.+"}` Loki queries directly without `trace_id` filter

## Related

- `docs/ARCHITECTURE.md §Observability stack` — SLI catalog and tiers
- `docs/OPERATIONS.md §SLO budget-burn troubleshooting` — quick dashboard navigation
- `platform/observability/mimir-ruler-rules/platform-slos.yaml` — T1/T2 recording rules + MWMBR alerts
- `platform/observability/mimir-ruler-rules/sli-recording-rules.yaml` — A/B/C tier recording rules
- `.claude/kb/sre-slo-engineering/_index.md` — MWMBR math and burn-rate formulas
