# Architecture

## Overview

WhisperOps is an Internal Developer Platform that provisions governed, observable Data Analyst agents over curated datasets. Operators use a Backstage scaffolder form to spin up a complete agent system (Planner orchestrating Analyst + Writer) in under 90 seconds of ArgoCD sync time. Each agent is fully isolated: its own Kubernetes namespace, GCS bucket, GCP service account, sandbox MCP pod, and chat-frontend pod.

## Layer Diagram

```
EXTERNAL
  Vertex AI (us-central1-aiplatform.googleapis.com — Gemini 2.5 Flash)
  OpenAI API (text-embedding-3-small — used by kagent UI sidecar)
  Langfuse (self-hosted in-cluster via Helm — LLM trace viewer + cost UI)
  Let's Encrypt (TLS via cert-manager)
  Operator (gcloud, age key, kubectl)

GCP PROJECT (Terraform-managed)
  VPC + subnet + firewall + per-deploy external IP + sslip.io DNS
  Vertex AI API (aiplatform.googleapis.com)
  SA whisperops-kagent-vertex (roles/aiplatform.user — inference only)
  SA whisperops-tempo-writer (roles/storage.objectAdmin on tempo-blocks bucket)
  SA whisperops-grafana-gcm (roles/monitoring.viewer — GCP Cloud Monitoring)
  Cloud SQL Postgres whisperops-langfuse-pg (Langfuse application DB)
  GCE e2-standard-8 VM (32 GB RAM / 8 vCPU, 100 GB SSD)
    kind cluster (single-node)
      IDP Layer (idpbuilder/CNOE, vendored)
        Backstage  ArgoCD  Gitea  Keycloak  ESO  cert-manager  NGINX-Ingress
      Application Platform Layer (helmfile + ArgoCD app-of-apps)
        kagent v0.9.x (CRDs separate chart; controller pod mounts Vertex SA key
          natively via controller.volumes; postRenderer scope: UI nginx-timeout only)
        Crossplane (GCP family providers + ProviderConfig — split sync waves)
        Kyverno  Reflector  ar-pull-secret rotation  budget-controller
        LGTM-distributed (Loki + Mimir + Grafana + 8 platform dashboards)
        Grafana Tempo (single-binary v1.24.4, GCS WAL)
        OTel Collector (traces+metrics+logs pipelines)
        Grafana Alloy (DaemonSet log collector)
        prometheus-node-exporter  kube-state-metrics
        Mimir Ruler (4 ConfigMaps: SLOs + budget-burn + SLI recording + meta)
        Langfuse (self-hosted v1.5.29 + Cloud SQL Auth Proxy sidecar)
      Per-Agent Layer (Backstage → Gitea → ArgoCD)
        namespace: agent-{name}
          agent-prompts ConfigMap (planner.md / analyst.md / writer.md)
          Planner / Analyst / Writer (kagent Agent CRs v1alpha2 Declarative,
            each its own Deployment; A2A routing via controller :8083)
          Sandbox MCP (FastAPI + FastMCP)  Chat Frontend (Next.js)
          Crossplane: Bucket + ServiceAccount + ServiceAccountKey + IAM bindings
          Kyverno namespaced policies (allow-a2a NetworkPolicy :8083)  per-agent Ingress
```

## Component Responsibilities

### Backstage scaffolder
Entry point for operators. The `dataset-whisperer` template renders Nunjucks skeleton files into a Gitea PR that ArgoCD then syncs. Form fields visible to the operator: `agent_name`, `description`, `dataset_id` (enum), `budget_usd`. Hidden fields `base_domain` and `project_id` are sed-baked into the template by `_vm-bootstrap` from the live VM IP and project ID at deploy time, so operators never type them.

### ArgoCD (app-of-apps)
The `root-app` Application is applied at the end of `_vm-bootstrap`. It watches `platform/argocd/applications/` in the in-cluster Gitea repo and instantiates child Applications for `crossplane-providers`, `crossplane-provider-config`, `budget-controller`, `kyverno-policies`, `observability`, `agent-prompts`, `ar-pull-secret`, and `reflector`. Per-agent Applications are added when operators scaffold via Backstage.

### kagent
Kubernetes-native LLM agent runtime. Manages `Agent`, `ModelConfig`, and `ToolServer` CRDs at `kagent.dev/v1alpha2` (stored version; v1alpha1 still served via conversion webhook). The CRDs ship as a separate Helm chart (`kagent-crds`) installed first via helmfile `needs:` ordering so the main `kagent` chart can register CRs without a CRD-establish race.

In v0.9.x, each Agent CR scaffolds its own Kubernetes Deployment + Service. The three agent roles (planner/analyst/writer) run as separate pods communicating over native A2A HTTP through the kagent-controller at port 8083. System prompts are stored in a per-agent-namespace `agent-prompts` ConfigMap (keys: `planner.md`, `analyst.md`, `writer.md`) referenced by `spec.declarative.systemMessageFrom`.

### Sandbox MCP (per agent)
One FastAPI Deployment per `agent-{name}` namespace running an MCP server over streamable-HTTP. Exposes a single tool (`execute_python_<agent>` — namespaced per-agent because kagent's tool registry has a global UNIQUE constraint on `tool.name`). Enforces: 60s subprocess timeout, 4 Gi memory limit (`setrlimit RLIMIT_AS`), read-only root filesystem, NetworkPolicy egress restricted to GCS + DNS + the in-cluster OTel collector. Mounts the agent's GCP SA key from the namespace's `gcp-sa-key` Secret — no per-call credential passing.

### Chat Frontend (per agent)
Next.js app exposing a chat UI at `agent-{name}.{vm-ip}.sslip.io:8443`. The `/api/chat` route opens an SSE stream from the browser, creates a kagent session via `POST /api/sessions/{id}/invoke/stream`, translates kagent's event stream into the SSE shape the browser consumes, and forwards Writer tokens. Marked `force-dynamic` so Next.js does not freeze `process.env` at build time.

### Crossplane
GCP family providers (`provider-gcp-storage`, `provider-gcp-iam`, `provider-gcp-cloudplatform`, `provider-family-gcp`) reconcile per-agent resources from CRDs the Backstage template emits: `Bucket/agent-{name}`, `ServiceAccount/agent-{name}`, `ServiceAccountKey` (which writes its own connection Secret to the agent namespace), and two `ProjectIAMMember` bindings (admin own bucket, read shared datasets bucket). The `crossplane-providers` and `crossplane-provider-config` ArgoCD apps are split on separate sync waves to avoid a CRD-establish race.

### Reflector + ar-pull-secret rotation
A source `ar-pull-secret-source` Secret in `crossplane-system` holds an Artifact Registry access token. A 30-min CronJob refreshes the token via `gcloud auth print-access-token`. Reflector replicates the Secret into every `agent-*` namespace so per-agent pods can pull `us-central1-docker.pkg.dev/.../whisperops-images/...` without per-namespace ESO plumbing.

### budget-controller
Polls the Mimir Ruler alerts API (`/prometheus/api/v1/alerts`) every 60 s for alerts with `state=firing` and `labels.action=killswitch`. The `BudgetBurnPage` rule (in `mimir-ruler-budget-burn`) fires when per-agent `whisperops_spend_usd:cumulative` reaches or exceeds the agent's `whisperops.io/budget-usd` annotation. At that threshold the controller scales all Deployments in the agent namespace to 0 replicas. At 80% a `BudgetBurnWarn` alert fires (severity: warn) — the controller surfaces this as a Kubernetes Warning Event without scaling.

### Observability stack

17-component LGTM+ stack deployed in the `observability` namespace.

**Signal collection:**
- **Grafana Alloy** (DaemonSet, v1.7.0) — Kubernetes log collection. Tails `/var/log/containers/` via `loki.source.kubernetes`, extracts `trace_id` and `level` from JSON log bodies via `loki.process` pipeline stages, and forwards to Loki. Replaces deprecated Promtail.
- **OTel Collector** — three pipelines: traces (OTLP → Tempo + Langfuse dual-export), metrics (OTLP + Prometheus scrape → Mimir remote-write), logs (OTLP → Loki). Prometheus scrape targets: node-exporter (:9100), kube-state-metrics (:8080), kagent (:8080), ArgoCD, Crossplane (:8080), Kyverno (:8000), OTel self-metrics (:8888).
- **prometheus-node-exporter** (DaemonSet, v4.55.0) — host-level CPU, memory, disk, network metrics.
- **kube-state-metrics** (v6.5.0) — Kubernetes object state metrics (pods, deployments, PVCs).

**Storage and query backends:**
- **LGTM-distributed** (Loki + Mimir + Grafana) — Loki ingests logs; Mimir stores metrics from OTel Collector remote-write plus Mimir Ruler-evaluated recording rules.
- **Grafana Tempo** (single-binary, v1.24.4) — trace backend. GCS-backed WAL + blocks (`gs://whisperops-tempo-blocks/`). The lgtm-distributed Tempo sub-chart is disabled (its distributor enforces a 2-ingester minimum). Metrics-generator emits `traces_spanmetrics_calls_total` and `traces_spanmetrics_latency` recording rules into Mimir — these power the A2A latency SLIs without OTel SDK instrumentation on kagent.
- **Self-hosted Langfuse** (v1.5.29, Helm chart) — LLM trace viewer and cost UI, backed by Cloud SQL Postgres via Cloud SQL Auth Proxy sidecar. Receives traces from OTel Collector `otlphttp/langfuse` exporter.

**Rules and alerting:**
- **Mimir Ruler** — evaluates SLI recording rules every 30s from four ConfigMaps (labeled `mimir-ruler-rules: "1"`):
  - `mimir-ruler-platform-slos` — T1 chat-frontend availability/TTFT/e2e/Apdex, T2 sandbox success SLIs, MWMBR page+warn alerts
  - `mimir-ruler-budget-burn` — per-agent spend recording rules, `BudgetBurnPage` (action: killswitch) at 100% budget
  - `mimir-ruler-sli-recording-rules` — A/B/C tier SLIs: kagent A2A latency/errors, Vertex availability, ArgoCD, Crossplane, Kyverno
  - `mimir-ruler-meta-observability` — OTel Collector health, queue saturation, Mimir ruler eval failures

**Dashboards:**
Eight platform dashboards in Grafana folder `platform/` (auto-discovered by Grafana sidecar via `grafana_dashboard: "1"` label on ConfigMaps):
D1 Cluster Health, D2 LLM Platform Overview, D4 SLO Compliance, D5 Service Map, D6 Cost and Tokens, D7 RED Method per Agent, D8 Apdex per Agent, D9 ArgoCD/Crossplane Platform Health.

Per-agent detail dashboards are provisioned automatically at scaffold time via the `observability/dashboard-configmap.yaml.njk` Backstage skeleton file (Grafana folder `k8s/{agent_name}/`).

**Cloud resources (Terraform-managed, per Rule #12):**
- `gs://whisperops-tempo-blocks/` — Tempo WAL + block storage (30-day lifecycle rule)
- `whisperops-tempo-writer@` SA — `roles/storage.objectAdmin` on tempo-blocks bucket
- `whisperops-grafana-gcm@` SA — `roles/monitoring.viewer` for GCP Cloud Monitoring datasource
- Cloud SQL Postgres instance `whisperops-langfuse-pg` — Langfuse application database

## Data Flow: Provisioning (≤ 90 s after PR merge)

1. Operator submits the Backstage form (4 visible fields) → scaffolder task created.
2. Nunjucks skeleton files rendered with sed-baked `base_domain` + `project_id` → committed to Gitea repo `whisperops/agent-{name}/`.
3. The repo's ArgoCD Application detects the new path → syncs from `manifests/` subfolder.
4. Sync wave order: Namespace → `agent-prompts` ConfigMap (wave 0) → Crossplane resources (Bucket + SA + Key + IAMMember) → kagent ModelConfig (wave 1) + Agent CRs (planner/analyst/writer v1alpha2 Declarative, wave 2) + Kyverno Policy (wave 2, generates `allow-a2a` NetworkPolicy for :8083) → Sandbox + Chat Frontend Deployments + Service + Ingress.
5. Reflector replicates `ar-pull-secret`, `langfuse-credentials`, and `kagent-vertex-credentials` into the new namespace within seconds.
6. cert-manager issues TLS for `agent-{name}.{vm-ip}.sslip.io` → chat UI is live.

## Data Flow: Query Runtime (p50 ≈ 15 s, p95 ≈ 30 s)

1. User types question → browser opens SSE to chat-frontend `/api/chat`.
2. Route handler creates a kagent session via `POST /api/sessions`, then invokes the planner via `POST /api/sessions/{id}/invoke/stream`.
3. Planner (Gemini 2.5 Flash via Vertex AI, kagent Agent CR v1alpha2 Declarative) orchestrates via native A2A: sends an A2A request through kagent-controller :8083 to the Analyst pod, then similarly to the Writer pod.
4. Analyst calls the Sandbox MCP `execute_python_<agent>` tool. Sandbox subprocess loads the dataset CSV from `gs://whisperops-datasets/`, runs the user code with `pd`/`np`/`plt`/`df` pre-loaded, uploads any chart PNGs to `gs://agent-{name}/charts/`, returns `{stdout, signed_chart_url, error?}`.
5. Writer composes markdown prose with chart embeds and code blocks, streams tokens back via SSE.
6. Browser renders tokens incrementally; charts render inline.
7. The OTel Collector dual-exports the trace to both Tempo (queryable via Grafana TraceQL) and Langfuse Cloud (cost rollup view). The trace hierarchy includes `a2a.request` spans propagated via W3C `traceparent` across pod boundaries: `planner.invoke → a2a.request → analyst.handle → analyst.llm.call → a2a.request → writer.handle → writer.llm.call`.

## Security Controls

| Control | Implementation |
|---------|---------------|
| Network isolation | Per-namespace NetworkPolicy generated by the Backstage skeleton |
| Sandbox egress | NetworkPolicy: GCS + DNS + in-cluster OTel collector only |
| No privilege escalation | Pod spec: `runAsNonRoot`, `readOnlyRootFilesystem`, `allowPrivilegeEscalation: false`, `capabilities: drop: [ALL]`, `automountServiceAccountToken: false` |
| Secret lifecycle | Terraform creates SAs + random_password resources; per-SA Makefile targets generate fresh keys per deploy and apply as K8s Secrets; Reflector replicates cross-namespace. No git-stored credentials. See [`SECRETS.md`](SECRETS.md). |
| Image registry allowlist | The namespaced `agent-egress-policy` is currently enforced; cluster-wide Kyverno policies are tracked in `PENDING_whisperops.md §B5` |
| Budget enforcement | budget-controller scales agent Deployments to 0 at 100% spend (degraded — see `PENDING_whisperops.md §A2`) |
| Resource limits | Agent Pod templates declare CPU + memory limits; Kyverno namespaced policy validates (cluster-wide enforcement pending) |

## Storage Layout

```
gs://{project}-tfstate/                    # Terraform remote state
gs://{project}-datasets/                   # Shared, read-only for agents
  california-housing.csv
  online-retail-ii.csv
  spotify-tracks.csv
gs://agent-{name}/                         # Per-agent, R/W via mounted SA key
  charts/{uuid}.png                        # Chart artifacts uploaded by sandbox
gs://whisperops-tempo-blocks/              # Tempo WAL + trace block storage (30-day lifecycle)
```

The `whisperops-images` Artifact Registry repo (provisioned by Terraform) holds the three whisperops-owned images: `budget-controller`, `chat-frontend`, `sandbox`.

## See also

- [`OPERATIONS.md`](OPERATIONS.md) — operator handbook (deploy chain, agent lifecycle, observability navigation)
- [`SECRETS.md`](SECRETS.md) — credentials inventory (ephemeral SA keys + Terraform random_password)
- [`SECURITY.md`](SECURITY.md) — threat model, residual risks, IAM scoping
- [`runbooks/incident-response.md`](runbooks/incident-response.md) — incident procedures
- `.claude/sdd/features/DESIGN_whisperops.md` — full architecture spec (internal)
- `.claude/sdd/features/PENDING_whisperops.md` — internal backlog
