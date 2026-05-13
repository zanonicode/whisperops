# Architecture

## Overview

WhisperOps is an Internal Developer Platform that provisions governed, observable Data Analyst agents over curated datasets. Operators use a Backstage scaffolder form to spin up a complete agent system (Planner orchestrating Analyst + Writer) in under 90 seconds of ArgoCD sync time. Each agent is fully isolated: its own Kubernetes namespace, GCS bucket, GCP service account, sandbox MCP pod, and chat-frontend pod.

## Layer Diagram

```
EXTERNAL
  Vertex AI (us-central1-aiplatform.googleapis.com — Gemini 2.5 Flash)
  OpenAI API (text-embedding-3-small — used by kagent UI sidecar)
  Langfuse Cloud US (LLM traces + cost rollups)
  Let's Encrypt (TLS via cert-manager)
  Operator (gcloud, age key, kubectl)

GCP PROJECT (Terraform-managed)
  VPC + subnet + firewall + per-deploy external IP + sslip.io DNS
  Vertex AI API (aiplatform.googleapis.com)
  SA whisperops-kagent-vertex (roles/aiplatform.user — inference only)
  GCE e2-standard-8 VM (32 GB RAM / 8 vCPU, 100 GB SSD)
    kind cluster (single-node)
      IDP Layer (idpbuilder/CNOE, vendored)
        Backstage  ArgoCD  Gitea  Keycloak  ESO  cert-manager  NGINX-Ingress
      Application Platform Layer (helmfile + ArgoCD app-of-apps)
        kagent v0.9.x (CRDs separate chart; controller pod mounts Vertex SA key
          natively via controller.volumes; postRenderer scope: UI nginx-timeout only)
        Crossplane (GCP family providers + ProviderConfig — split sync waves)
        Kyverno  Reflector  ar-pull-secret rotation  budget-controller
        LGTM-distributed (Loki + Mimir + Grafana)
        OTel Collector  tempo-mono (single-binary tracing backend)
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
The `root-app` Application is applied at the end of `_vm-bootstrap`. It watches `platform/argocd/applications/` in the in-cluster Gitea repo and instantiates child Applications for `crossplane-providers`, `crossplane-provider-config`, `budget-controller`, `kyverno-policies`, `observability`, `agent-prompts`, `platform-bootstrap-job`, `ar-pull-secret`, and `reflector`. Per-agent Applications are added when operators scaffold via Backstage.

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
Polls Langfuse REST API every 60 s for per-agent spend; compares against the `whisperops.io/budget-usd` annotation on each agent's namespace. At 80%: emits a K8s Warning Event + Prometheus counter. At 100%: scales all Deployments in the agent namespace to 0 replicas.

> The kill-switch path is currently fragile (Langfuse REST + OTel pipeline drift exposed during a prior cycle). See `PENDING_whisperops.md §A2`.

### Observability stack
LGTM-distributed (Loki + Mimir + Grafana) plus a standalone single-binary `tempo-mono` for tracing (the lgtm-distributed Tempo sub-chart is disabled because its distributor enforces a 2-ingester minimum that doesn't fit a single-node kind cluster). The OTel Collector dual-exports traces to both Tempo (in-cluster) and Langfuse Cloud (`otlphttp/langfuse` exporter). Grafana also queries Langfuse REST via the Infinity datasource for the cost-rollup dashboard.

> Tempo currently uses in-memory storage; durable WAL/blocks are tracked in `PENDING_whisperops.md §B3`.

### Platform-bootstrap Job (dormant)
A one-shot Kubernetes Job intended to populate dataset profile JSON in Supabase pgvector. **Currently dormant** — Supabase is provisioned via SOPS-encrypted credentials but no runtime component reads from it; the Planner uses a literal `dataset_id` baked into its system prompt at scaffold time, not a runtime profile lookup. See `PENDING_whisperops.md §C1` for the wire-or-delete decision.

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
| Secret lifecycle | SOPS+age in git → ESO (where used) + Reflector cross-namespace replication. Bootstrap SA key and Vertex SA key generated fresh per deploy |
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
```

The `whisperops-images` Artifact Registry repo (provisioned by Terraform) holds all four whisperops-owned images: `budget-controller`, `chat-frontend`, `sandbox`, `platform-bootstrap`.

## See also

- [`OPERATIONS.md`](OPERATIONS.md) — operator handbook (deploy chain, agent lifecycle, observability navigation)
- [`SECRETS.md`](SECRETS.md) — SOPS + age workflow
- [`SECURITY.md`](SECURITY.md) — threat model, residual risks, IAM scoping
- [`runbooks/incident-response.md`](runbooks/incident-response.md) — incident procedures
- `.claude/sdd/features/DESIGN_whisperops.md` — full architecture spec (internal)
- `.claude/sdd/features/PENDING_whisperops.md` — internal backlog
