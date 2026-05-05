# DESIGN: whisperops (Dataset Whisperer Platform)

> Technical design for an end-to-end Internal Developer Platform that ships isolated, governed, observable Data Analyst agents over curated datasets.

## Metadata

| Attribute | Value |
|-----------|-------|
| **Feature** | whisperops |
| **Date** | 2026-05-04 |
| **Author** | design-agent |
| **DEFINE** | [DEFINE_whisperops.md](./DEFINE_whisperops.md) |
| **BRAINSTORM** | [BRAINSTORM_whisperops.md](./BRAINSTORM_whisperops.md) |
| **Source Plan** | [notes/PLAN_dataset-whisperer.md](../../../notes/PLAN_dataset-whisperer.md) |
| **Status** | Ready for Build |

---

## Pre-flight: Ground-truth dataset facts (May 2026)

Operator has placed three zip archives at `datasets/` in the working directory. Inspecting them produces facts that *change one assumption from DEFINE*:

| Dataset | Archive | Uncompressed CSV | Filename in zip | Source-plan estimate | Variance |
|---------|---------|------------------|-----------------|---------------------|----------|
| California Housing | `california-housing-prices.zip` (400 KB) | **1.4 MB** | `housing.csv` | (not specified) | OK |
| Online Retail II (UCI) | `online-retail-ii-uci.zip` (15 MB) | **95 MB** | `online_retail_II.csv` | ~45 MB | **2.1× larger** |
| Spotify Tracks | `spotify-tracks.zip` (8.4 MB) | **20 MB** | `dataset.csv` | (not specified) | OK |

**Implication:** DEFINE A-001 (sandbox memory headroom, 3 GB cap, worst-case ~1.5 GB peak per source plan §2.5) was sized against a 45 MB assumption. With Online Retail II at 95 MB:

- pandas peak after dtype inference ≈ **~330 MB** (was ~150 MB in plan)
- Worst-case ops (groupby + merge + pivot, 2-3× DataFrame): **~990 MB** (was ~450 MB)
- Library footprint stays at ~660 MB
- **Total worst-case peak ≈ ~1.65 GB** — still inside the 3 GB cap, but the headroom is roughly 1.35 GB instead of 1.5 GB (and that includes interpreter overhead, plot rendering, scipy pivot intermediaries)

This is **tight but viable**. /build's first task is a memory-spike validation (Section 12 below). If the spike shows real-world usage closer to the cap than estimated, two pre-planned mitigations exist:

- (a) Raise the sandbox cgroup limit to 4 GB — VM has 32 GB, headroom is comfortable
- (b) Add a "max-rows" pre-flight check in the Analyst's code-gen prompt for Online Retail specifically (sample to 100k rows)

**Decision:** Keep 3 GB limit at /design lock; treat the spike result as the gate to decide between (a), (b), or no change.

**Bucket convention (resolved here):** Operator unzips locally before upload. Final bucket layout (flat — `make upload-datasets` does `gcloud storage cp datasets/*.csv gs://bucket/`):

```text
gs://{project-id}-datasets/
├── california-housing-prices.csv
├── online_retail_II.csv
└── spotify-tracks.csv
```

The `dataset_id` slug in the Backstage form dropdown (`california-housing` / `online-retail-ii` / `spotify-tracks`) maps to a CSV filename via the `dataset_profile.csv_filename` field — slugs are user-facing labels; filenames are bucket keys. Mapping authority lives in the platform-bootstrap profile JSON (DD-3).

---

## 1. Architecture Overview

```text
┌────────────────────────────────────────────────────────────────────────────────┐
│                        EXTERNAL (operator's laptop / SaaS)                     │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────────┐  ┌──────────────┐ │
│  │ Anthropic│  │  OpenAI  │  │ Supabase │  │   Langfuse   │  │   Operator   │ │
│  │  (Haiku, │  │  (embed- │  │ (Postgres│  │    Cloud     │  │   (gcloud,   │ │
│  │  Sonnet) │  │  ddings) │  │+pgvector)│  │  (LLM traces)│  │  age key)    │ │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘  └──────┬───────┘  └──────┬───────┘ │
└───────┼────────────┼────────────┼───────────────┼──────────────────┼──────────┘
        │            │            │               │                  │
        │            │            │               │                  │ TF apply / SOPS / kubectl
┌───────┼────────────┼────────────┼───────────────┼──────────────────▼──────────┐
│       │            │            │               │                             │
│       │   GCP project (Terraform-owned cloud floor)                           │
│       │   ┌─────────────────────────────────────────────────────────────┐    │
│       │   │ VPC + firewall + static external IP + DNS via sslip.io      │    │
│       │   │ GCE e2-standard-8 VM (32 GB / 8 vCPU)                       │    │
│       │   │ ┌──────────────────────────────────────────────────────┐   │    │
│       │   │ │            kind cluster (single-node)                │   │    │
│       │   │ │                                                      │   │    │
│       │   │ │  ┌────────────────────────────────────────────────┐  │   │    │
│       │   │ │  │  IDP layer (idpBuilder bootstrap)              │  │   │    │
│       │   │ │  │  Backstage  ArgoCD  Gitea  Keycloak  ESO       │  │   │    │
│       │   │ │  │  Crossplane  NGINX-Ing  cert-manager           │  │   │    │
│       │   │ │  └────────────────────────────────────────────────┘  │   │    │
│       │   │ │  ┌────────────────────────────────────────────────┐  │   │    │
│       │   │ │  │  Platform layer (Helmfile + ArgoCD app-of-apps)│  │   │    │
│       │   │ │  │  kagent  LGTM  OTel-Collector  Kyverno         │  │   │    │
│       │   │ │  │  provider-gcp  Sandbox pool (1-2 pods)         │  │   │    │
│       │   │ │  └────────────────────────────────────────────────┘  │   │    │
│       │   │ │  ┌────────────────────────────────────────────────┐  │   │    │
│       │   │ │  │  Per-agent layer (Backstage→Gitea→ArgoCD)      │  │   │    │
│       │   │ │  │   namespace agent-{name}-{xyz}                 │  │   │    │
│       │   │ │  │     ┌─────────┐  ┌─────────┐  ┌─────────┐      │  │   │    │
│       │   │ │  │     │ Planner │→ │ Analyst │→ │ Writer  │ A2A  │  │   │    │
│       │   │ │  │     │ (Haiku) │  │ (sel'd) │  │ (sel'd) │      │  │   │    │
│       │   │ │  │     └─────────┘  └────┬────┘  └─────────┘      │  │   │    │
│       │   │ │  │                       │                        │  │   │    │
│       │   │ │  │                       ▼                        │  │   │    │
│       │   │ │  │     ┌─────────┐  Sandbox /execute (HTTP)       │  │   │    │
│       │   │ │  │     │  Chat   │←──────────────────────────────┘│  │   │    │
│       │   │ │  │     │ Frontend│                                │  │   │    │
│       │   │ │  │     └─────────┘                                │  │   │    │
│       │   │ │  └────────────────────────────────────────────────┘  │   │    │
│       │   │ └──────────────────────────────────────────────────────┘   │    │
│       │   └─────────────────────────────────────────────────────────────┘    │
│       │                                                                       │
│       │   Buckets:                                                            │
│       │   ├── gs://{project}-tfstate           (TF state)                     │
│       │   ├── gs://{project}-datasets          (TF-owned, MANUAL UPLOAD)      │
│       │   └── gs://{project}-agent-{name}-{xyz} (Crossplane-owned, per-agent) │
│       │                                                                       │
│       │   IAM:                                                                │
│       │   ├── bootstrap SA (TF-owned, scoped: manage agent-* buckets/SAs)     │
│       │   └── agent SA (Crossplane-owned, per-agent: read shared+admin own)   │
└──────────────────────────────────────────────────────────────────────────────┘
```

---

## 2. Components

| # | Component | Purpose | Technology | Owner Tier |
|---|-----------|---------|------------|------------|
| 1 | **Cloud floor** | VPC, firewall, static IP, GCE VM, shared GCS buckets, bootstrap SA | Terraform (HCL), GCP provider, GCS state backend | TF |
| 2 | **kind cluster** | Single-node K8s on the VM | kind, containerd, kindnet | TF (via VM startup script) |
| 3 | **idpBuilder bootstrap** | Backstage + ArgoCD + Gitea + Keycloak + Crossplane core + ESO + NGINX-Ingress + cert-manager | idpBuilder binary, Helm | TF (via VM startup script) |
| 4 | **Platform-layer charts** | kagent, LGTM, OTel Collector, Kyverno, provider-gcp config | Helmfile + ArgoCD app-of-apps; Helm charts (vendor + project-local) | Cluster (in-band IaC) |
| 5 | **Sandbox service** | Pre-warmed pod pool that executes LLM-generated Python with per-execution credentials | Python 3.12 + FastAPI + uvicorn; subprocess-isolated; cgroup-limited | Cluster |
| 6 | **Backstage template** | 4-field form → generates Crossplane CRDs + kagent Agent CRDs + chat-frontend manifests + ArgoCD Application; opens PR to Gitea | Backstage scaffolder, Nunjucks (.njk) templating | Cluster |
| 7 | **Crossplane Compositions** | Reusable composite resource definitions for per-agent cloud bundle (bucket + SA + key + IAM) | Crossplane v1.x XR / Composition; provider-gcp | Cluster |
| 8 | **kagent Agents (×3 per Dataset Whisperer)** | Planner, Analyst, Writer — A2A-orchestrated; OTel-instrumented | kagent CRD; Anthropic SDK; A2A protocol | Per-agent |
| 9 | **Chat frontend** | Per-agent web UI: SSE stream, markdown render, chart embed, code blocks | Next.js (App Router) + TypeScript + Tailwind + browser OTel SDK | Per-agent |
| 10 | **Platform-bootstrap pod** | One-shot Job: reads CSVs from shared bucket, generates dataset profile JSON + embeddings, writes to Supabase pgvector and (optionally) commits to repo | Python 3.12 + pandas + Anthropic + OpenAI + Supabase SDK | Cluster (one-shot) |
| 11 | **CI smoke evals** | Validate Agent CRD PRs structurally; run 1 fixed test question per dataset | GitHub Actions; ephemeral kind via `setup-kind` action | External |
| 12 | **Observability bundle** | LGTM stack + OTel Collector + Grafana dashboards + Kyverno-emitted PolicyReport | Grafana, Loki, Tempo, Prometheus, Mimir, OTel Collector, Grafana Infinity datasource | Cluster |
| 13 | **Kyverno policies** | enforce/audit policies on agent namespaces and platform | Kyverno ClusterPolicy YAML | Cluster |
| 14 | **Secrets pipeline** | SOPS+age encrypted in git → applied to cluster → ESO syncs into agent namespaces | SOPS, age, External Secrets Operator | Hybrid |
| 15 | **Makefile** | One-command deploy + destroy + smoke-test orchestrator | GNU Make + shell | Local |

---

## 3. Key Decisions

> Decisions made during /design that resolve DEFINE Open Questions (OQ-1 through OQ-6) and add new clarifications. Inherited decisions from BRAINSTORM (D-001 through D-020) and DEFINE (D-001 through D-007) remain in force.

### Decision DD-1: Backstage scaffolder uses Nunjucks (.njk) templating

| Attribute | Value |
|-----------|-------|
| **Status** | Accepted |
| **Resolves** | DEFINE OQ-1 |

**Context:** Backstage scaffolder supports multiple templating languages; source plan §4 lists `.njk` files.

**Choice:** Adopt Nunjucks (`.njk`) for all template files in `backstage-templates/dataset-whisperer/skeleton/`.

**Rationale:** Nunjucks is the historical default for Backstage scaffolder, has the largest ecosystem of community examples, and matches the source plan's repo layout literally — minimizing "translation" cost during /build. As of Backstage v1.x (current in May 2026), Nunjucks remains supported.

**Alternatives Rejected:**
1. Handlebars — supported but rarer in Backstage examples; no advantage here.
2. Mustache — too limited (no logic); fails for the conditional `${{ values.primary_model }}` substitutions.

**Consequences:**
- /build pulls patterns from Backstage's own scaffolder docs and community templates.
- Variable substitution syntax: `{{ values.agent_name }}` (Nunjucks), not `${{ ... }}` (GitHub Actions style).

---

### Decision DD-2: Backstage emits raw Crossplane CRDs in MVP, not a wrapped XR/Composition

| Attribute | Value |
|-----------|-------|
| **Status** | Accepted |
| **Resolves** | DEFINE OQ-2 |

**Context:** Per-agent cloud resources can be expressed as (a) raw `Bucket`, `ServiceAccount`, `ServiceAccountKey`, `IAMMember` CRDs in the template skeleton, or (b) wrapped in a single `XAgentResources` Composition with a `claim`-style abstraction.

**Choice:** Raw CRDs in MVP. Composition wrapping is deferred to v0.4.

**Rationale:** A Composition adds a Crossplane-specific authoring task (XR definition + Composition definition + claim type) before the Backstage template even works. For a learning project where each piece needs to be visible end-to-end, raw CRDs make the GitOps flow inspectable: a developer reads the Gitea PR and sees exactly what cloud resources will be created. Composition is the right next step (v0.4) once the per-agent shape stabilizes.

**Alternatives Rejected:**
1. Wrapped Composition — premature abstraction; hides the resource shape during a learning phase.
2. Pure Terraform per-agent — defeats the GitOps-everything goal (BRAINSTORM D-003).

**Consequences:**
- Backstage skeleton has 4 separate Crossplane manifest files (`bucket.yaml.njk`, `service-account.yaml.njk`, `service-account-key.yaml.njk`, `iam-bindings.yaml.njk`) instead of one `xresource.yaml.njk`.
- Refactoring path to v0.4: define `XAgentResources` Composition matching the current 4-CRD shape, migrate template to emit a single claim. Bounded change.

---

### Decision DD-3: platform-bootstrap is a one-shot Kubernetes Job, rerunnable

| Attribute | Value |
|-----------|-------|
| **Status** | Accepted |
| **Resolves** | DEFINE OQ-3 |

**Context:** After DEFINE D-001 / D-003, the bootstrap pod no longer downloads datasets — it generates profile JSON + embeddings from already-uploaded CSVs in the shared bucket, writes to Supabase pgvector, and (optionally) commits the JSON to the platform repo.

**Choice:** Implement as a Kubernetes `Job` (not CronJob, not a kagent Agent). The Job runs once per `make deploy`, is idempotent (skips datasets whose profile hash already exists in Supabase), and can be re-triggered manually via `kubectl create job --from=cronjob/...` semantics or `make regenerate-profiles`.

**Rationale:**
- **Not a CronJob:** profiles are static after first generation; periodic re-run is waste.
- **Not a kagent Agent:** profile generation is structured extraction over deterministic CSVs, not conversational. kagent's agent runtime adds zero value here.
- **One-shot Job:** matches K8s semantics for "run once, complete, exit cleanly." ArgoCD's `Sync wave` annotation orders it after Crossplane has produced bindings and before per-agent stacks are reconciled.

**Alternatives Rejected:**
1. CronJob with high interval — wasteful; profiles don't change.
2. kagent Agent — wrong tool for batch ETL.
3. Inline in the Makefile — couples local environment to platform internals (Anthropic/OpenAI/Supabase SDKs); also can't access in-cluster secrets.

**Consequences:**
- Idempotency check: `SELECT 1 FROM dataset_profiles WHERE source_hash = $1` before re-generating. Cheap.
- Failure handling: Job restarts up to 3 times; on persistent failure, ArgoCD shows it as Degraded. Operator runs `kubectl logs job/platform-bootstrap-<hash>` to debug.

---

### Decision DD-4: Random suffix is generated by Backstage scaffolder (custom action)

| Attribute | Value |
|-----------|-------|
| **Status** | Accepted |
| **Resolves** | DEFINE OQ-4 |

**Context:** The 3-character suffix `{xyz}` (lowercase alphanumeric) appended to all per-agent resource names must be generated *before* any manifest is rendered. Two locations: (a) inside Backstage's scaffolder via a custom action that runs before the `fetch:template` step, or (b) inside a Crossplane composition function that mutates resource names at admission time.

**Choice:** Backstage scaffolder custom action `whisperops:generate-suffix` runs as the first step of the template flow. Output is bound to `parameters.suffix` and substituted into the template via `{{ parameters.suffix }}`.

**Rationale:**
- Suffix must be visible in the PR's filename (`agents/{name}-{xyz}/`) — only the scaffolder controls filenames.
- Crossplane composition functions are a heavier abstraction (DD-2 already deferred them); doing this with a 20-line scaffolder action is proportionate.
- Determinism: action seeded by `Date.now() + agent_name` so a re-submission with the same name produces a different suffix (preventing GCS bucket name collisions on agent recreation, BRAINSTORM D-008).

**Alternatives Rejected:**
1. Composition function — overkill; needs separate authoring/release.
2. Random in template body via Nunjucks filter — Nunjucks doesn't have a portable random source; requires a custom filter, which is ~the same complexity as a scaffolder action.
3. Operator types the suffix into the form — burdens the user; defeats "4 fields, period" (BRAINSTORM D-006).

**Consequences:**
- Custom Backstage action lives at `backstage-templates/dataset-whisperer/actions/generate-suffix.ts` (TypeScript, registered in Backstage's app-config).
- Action is unit-testable: 100 invocations produce 100 distinct 3-char suffixes (collision rate negligible at 36³ = 46k namespace).

---

### Decision DD-5: Streaming protocol Writer→chat is SSE (Server-Sent Events)

| Attribute | Value |
|-----------|-------|
| **Status** | Accepted |
| **Resolves** | DEFINE OQ-5 |

**Context:** Token streaming from the Writer agent to the browser. Options: SSE (one-way server→client) vs WebSocket (bidirectional).

**Choice:** SSE.

**Rationale:**
- Writer→browser is unidirectional. WebSocket's bidirectionality is unused.
- Next.js App Router has first-class SSE support via `Response` with a `ReadableStream`. WebSocket needs a separate server (Next.js doesn't have native WS support in App Router).
- NGINX Ingress passes SSE through trivially; WebSocket needs `proxy_set_header Upgrade` plumbing (works, but extra config).
- SSE auto-reconnects on disconnect via the `EventSource` browser API.

**Alternatives Rejected:**
1. WebSocket — over-engineered for one-way data.
2. Long-polling — high latency, defeats the streaming UX.

**Consequences:**
- Chat frontend uses `EventSource` in the browser, served by a Next.js Route Handler that proxies to the Planner agent's HTTP endpoint.
- Planner→Analyst→Writer A2A hops are HTTP, not streaming; only the **final** Writer→browser hop streams. Earlier hops emit complete responses (with full reasoning text) before forwarding.

---

### Decision DD-6: OTel pipeline uses one Collector with a fan-out exporter

| Attribute | Value |
|-----------|-------|
| **Status** | Accepted |
| **Resolves** | DEFINE OQ-6 |

**Context:** Both Tempo (in-cluster) and Langfuse (cloud) need agent traces. Two designs: (a) one OTel Collector deployment with two exporters (`otlp/tempo` + `otlphttp/langfuse`), or (b) two separate exporter configs in each kagent Agent.

**Choice:** Single OTel Collector deployment in the `observability` namespace, configured as a sidecar-less central endpoint. Exporters: `otlp` to Tempo (gRPC) and `otlphttp` to Langfuse Cloud (HTTPS, with auth via header from a secret). Sandbox, chat-frontend, and kagent Agents all OTLP to this single Collector.

**Rationale:**
- Single point of configuration; rotating Langfuse credentials is one secret update.
- Collector handles batching, retries, sampling — agents don't.
- Standard OTel pattern.

**Alternatives Rejected:**
1. Per-agent dual-exporter config — duplicated configuration; rotation is painful.
2. Separate Collectors per backend — needless duplication.

**Consequences:**
- Collector config (`platform/helm/observability-extras/values.yaml`) defines the two exporters and a `service.pipelines.traces.exporters: [otlp/tempo, otlphttp/langfuse]`.
- Trace IDs are consistent across both backends — operator can correlate a Langfuse trace ID to a Tempo trace.

---

### Decision DD-7: Datasets uploaded as unzipped CSVs to slugged paths

| Attribute | Value |
|-----------|-------|
| **Status** | Accepted |
| **New (this /design session)** | Resolves bucket-layout question raised by ground-truth zip inspection |

**Choice:** Operator unzips locally and uploads flat to:

```text
gs://{project}-datasets/
├── california-housing-prices.csv
├── online_retail_II.csv
└── spotify-tracks.csv
```

Backstage form's `dataset_id` dropdown values: `california-housing`, `online-retail-ii`, `spotify-tracks` — these are user-facing slugs, **not** bucket paths. Planner agent reads `dataset_profile` keyed by `dataset_id`. Sandbox loads via `gs://{project}-datasets/{dataset_profile.csv_filename}` — the slug→filename mapping is the profile JSON's responsibility (DD-3).

**Rationale:** Unzipped CSVs avoid runtime decompression in the sandbox (CPU and memory), match the source plan's mental model of "datasets are CSVs," and let GCS lifecycle / versioning operate at the file level.

**Alternatives Rejected:**
1. Upload zips, decompress in sandbox — wastes sandbox memory at every read; complicates code generation (Analyst would need to know about zips).
2. Upload zips, decompress in bootstrap pod, write back — extra read/write, no benefit.

---

### Decision DD-8: Sandbox memory limit stays at 3 GB at /design lock; /build's first task is a memory spike

| Attribute | Value |
|-----------|-------|
| **Status** | Provisional, gated by spike result |
| **New (this /design session)** | Triggered by Online Retail II being 95 MB vs 45 MB plan estimate |

**Context:** With Online Retail II at 95 MB uncompressed (2.1× plan estimate), worst-case sandbox memory peak is now estimated at ~1.65 GB instead of the source plan's ~1.5 GB — still inside the 3 GB cgroup, but headroom shrunk from 1.5 GB to 1.35 GB.

**Choice:** Keep 3 GB at /design lock. /build's **Task #1** is a memory-spike validation: load `online_retail_II.csv` in a representative sandbox pod, run a groupby + merge + pivot operation, measure peak RSS. Decision rule:

| Spike result | Action |
|--------------|--------|
| Peak ≤ 2.0 GB | No change. 3 GB stands. |
| Peak 2.0–2.7 GB | No change. Document slim margin in residual risks. |
| Peak > 2.7 GB | Raise cgroup to 4 GB (VM has 32 GB; trivial change in `platform/helm/sandbox/values.yaml`). |
| OOM at 3 GB | Investigate per-query: does the Analyst prompt over-aggregate? If yes, prompt fix. Otherwise raise to 4 GB. |

**Rationale:** Don't pre-emptively raise the limit before measuring; don't pre-emptively prompt-engineer before knowing it's needed.

**Consequences:**
- Memory spike is a documented gate before any agent prompt iteration begins.
- Mitigation paths (a) / (b) from Pre-flight are pre-decided; spike chooses among them.

---

### Decision DD-9: Helmfile orchestrates platform-layer charts; ArgoCD app-of-apps tracks Gitea

| Attribute | Value |
|-----------|-------|
| **Status** | Accepted |

**Context:** Both Helmfile and ArgoCD Application can deploy charts. The platform layer (kagent, LGTM, OTel Collector, Kyverno, provider-gcp) needs initial deploy AND ongoing GitOps reconciliation.

**Choice:** Two-stage deploy:
1. **Bootstrap (one-shot, from Makefile):** `helmfile apply` against the kind cluster installs the platform layer charts and the `root-app` ArgoCD `Application` that watches Gitea.
2. **Steady state:** ArgoCD reconciles everything from Gitea (app-of-apps pattern). Helmfile is not used after bootstrap.

**Rationale:** ArgoCD is the long-term source-of-truth; Helmfile is the bootstrapper that gets ArgoCD itself wired up. After day 1, every change goes through git → Gitea → ArgoCD. Helmfile is only re-invoked if the cluster is rebuilt from scratch.

**Alternatives Rejected:**
1. ArgoCD-only from day 1 — chicken-and-egg: ArgoCD must be installed before it can install itself. Helmfile breaks that loop cleanly.
2. Helmfile-only — loses GitOps reconciliation on drift.

---

### Decision DD-10: Per-agent budget enforcement runs as a small in-cluster Operator (Python)

| Attribute | Value |
|-----------|-------|
| **Status** | Accepted |

**Context:** Per-agent budget kill switch (DEFINE goal MUST). Polling Langfuse costs and scaling agent Deployments to 0 needs a control loop.

**Choice:** Implement as a small Python service `budget-controller` running in the `whisperops-system` namespace. It polls Langfuse REST API every 60s, reads each agent's `budget` annotation from its kagent Agent CRD, computes burn rate, and emits two actions:
- 80% threshold → emit a `Warning` event on the Agent CRD; create an Alertmanager alert via Prometheus rule.
- 100% threshold → patch the Deployment(s) under the agent's namespace to `replicas: 0`; record a `BudgetExceeded` event.

**Rationale:**
- Avoids writing a CRD controller in Go (would be ideal long-term but is multi-day scope).
- Loop is short and well-bounded; ~150 LOC of Python.
- Uses existing observability surface (events visible in `kubectl get events`, Grafana picks up via `kube-state-metrics`).

**Alternatives Rejected:**
1. Pure Prometheus alert with no scaling — alerts only; doesn't enforce.
2. Go controller using kubebuilder — multi-day scope; too much for MVP.
3. Inline in each agent — agent can't reliably scale itself to 0.

**Consequences:**
- New file: `src/budget-controller/`. Single agent (`@python-developer`) owns it.
- The 60s poll interval bounds detection latency; A-009 in DEFINE assumes ≤ 60s — matches.

---

### Decision DD-11: kagent Agent CRD authors prompt as inline ConfigMap-bound text

| Attribute | Value |
|-----------|-------|
| **Status** | Accepted |

**Context:** Agent system prompts are large (~500-2000 tokens each for Planner / Analyst / Writer). Embedding them inline in the kagent Agent CRD is verbose; storing them in ConfigMaps and referencing them keeps the Agent CRD readable.

**Choice:** System prompts live in `platform/helm/agent-prompts/templates/configmap-{role}.yaml` (Helm-templated so each Dataset Whisperer agent reuses the same set). The Backstage template generates kagent `Agent` CRDs that reference these ConfigMaps via `spec.systemPromptConfigMapRef`. Prompt updates are a single Helm chart bump, not a per-agent template re-deploy.

**Rationale:** All Dataset Whisperer agents share the same Planner/Analyst/Writer prompts; only the *model* differs. Centralized prompts reduce drift and make prompt iteration a single PR instead of N (one per active agent).

**Alternatives Rejected:**
1. Inline in each Agent CRD — 3 × N agents of duplicated prompt text in git.
2. Prompts in Supabase — runtime fetch adds latency; updating prompts means a SQL migration.

**Consequences:**
- Prompt files: `prompt-planner.txt`, `prompt-analyst.txt`, `prompt-writer.txt` in the chart's `files/` directory (Helm reads them via `.Files.Get`).
- Prompt iteration: edit file → bump chart → ArgoCD re-syncs ConfigMap → kagent restarts agents. Bounded blast radius (kagent watches ConfigMap changes).

---

## 4. File Manifest

> All paths are relative to `/Users/vitorzanoni/whisperops/`. Greenfield — every file is a `Create` action. Dependencies use the `#` column. Agent assignments map to `.claude/agents/`.

### 4.1 Pre-flight (must come first)

| # | File | Action | Purpose | Agent | Dependencies |
|---|------|--------|---------|-------|--------------|
| 0 | (no file — git init) | Run | `git init`; create initial empty commit on `main` | (general) | None |
| 1 | `.gitignore` | Create | Exclude age key, terraform local state, node_modules, dist, __pycache__, .env*, .terraform/ | (general) | 0 |
| 2 | `.sops.yaml` | Create | SOPS rules: encrypt all `secrets/*.enc.yaml` with the project age public key | (general) | 0 |
| 3 | `README.md` | Create | Front-door: project pitch, prerequisites, `make deploy` quickstart, surface URLs, demo link placeholder | @code-documenter | 0 |
| 4 | `Makefile` | Create | `deploy`, `destroy`, `smoke-test`, `regenerate-profiles`, `upload-datasets`, `decrypt-secrets`, `lint` | @ci-cd-specialist | 1, 2 |

### 4.2 Cloud floor — Terraform (TF tier)

| # | File | Action | Purpose | Agent | Dependencies |
|---|------|--------|---------|-------|--------------|
| 5 | `terraform/main.tf` | Create | Root: provider, modules wiring, common tags | @infra-deployer | 1 |
| 6 | `terraform/variables.tf` | Create | `project_id`, `region`, `zone`, `vm_machine_type`, `allowed_ssh_cidr`, `state_bucket_name` | @infra-deployer | 5 |
| 7 | `terraform/outputs.tf` | Create | VM external IP, datasets bucket name, bootstrap SA email, kubeconfig path | @infra-deployer | 5 |
| 8 | `terraform/backend.tf` | Create | GCS state backend pointing at `{project}-tfstate` | @infra-deployer | 5 |
| 9 | `terraform/modules/network/main.tf` | Create | VPC, subnet, firewall (22 from `var.allowed_ssh_cidr`, 80, 443 from 0.0.0.0/0), static external IP | @infra-deployer | 5 |
| 10 | `terraform/modules/network/{variables,outputs}.tf` | Create | I/O for network module | @infra-deployer | 9 |
| 11 | `terraform/modules/compute/main.tf` | Create | GCE `e2-standard-8` VM with `var.startup_script`; attaches static IP; tags for firewall | @infra-deployer | 9 |
| 12 | `terraform/modules/compute/startup-script.sh` | Create | Install Docker, download idpBuilder binary, `idpbuilder create --use-path-routing`, write kubeconfig to operator's home | @infra-deployer | 11 |
| 13 | `terraform/modules/compute/{variables,outputs}.tf` | Create | I/O for compute module | @infra-deployer | 11 |
| 14 | `terraform/modules/storage/main.tf` | Create | **`{project}-tfstate` bucket** (versioned), **`{project}-datasets` bucket** (versioned, regional, public-access-prevention enforced) | @infra-deployer | 5 |
| 15 | `terraform/modules/storage/{variables,outputs}.tf` | Create | I/O for storage module | @infra-deployer | 14 |
| 16 | `terraform/modules/iam/main.tf` | Create | Bootstrap SA `whisperops-bootstrap@{project}` with scoped roles: `roles/storage.admin` constrained by IAM Conditions to `agent-*` and `{project}-agent-*` resources; `roles/iam.serviceAccountAdmin` constrained to `agent-*@` SAs; key creator on those SAs | @infra-deployer | 5 |
| 17 | `terraform/modules/iam/{variables,outputs}.tf` | Create | I/O for iam module | @infra-deployer | 16 |
| 18 | `terraform/envs/demo/terraform.tfvars` | Create | Demo env values for project_id, region, etc. (committed; does NOT contain secrets) | @infra-deployer | 6 |
| 19 | `terraform/envs/demo/backend.tfvars` | Create | Backend bucket name binding for demo env | @infra-deployer | 8 |

### 4.3 SOPS-encrypted secrets (committed encrypted)

| # | File | Action | Purpose | Agent | Dependencies |
|---|------|--------|---------|-------|--------------|
| 20 | `secrets/anthropic.enc.yaml` | Create (encrypted) | `ANTHROPIC_API_KEY` | (general, manual) | 2 |
| 21 | `secrets/openai.enc.yaml` | Create (encrypted) | `OPENAI_API_KEY` | (general, manual) | 2 |
| 22 | `secrets/supabase.enc.yaml` | Create (encrypted) | `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, `SUPABASE_ANON_KEY` | (general, manual) | 2 |
| 23 | `secrets/langfuse.enc.yaml` | Create (encrypted) | `LANGFUSE_PUBLIC_KEY`, `LANGFUSE_SECRET_KEY`, `LANGFUSE_HOST` | (general, manual) | 2 |
| 24 | `secrets/crossplane-gcp-creds.enc.yaml` | Create (encrypted) | Bootstrap SA JSON key (output of Terraform, encrypted before commit) | (general, manual) | 2, 16 |

### 4.4 Platform layer — ArgoCD app-of-apps + Helmfile

| # | File | Action | Purpose | Agent | Dependencies |
|---|------|--------|---------|-------|--------------|
| 25 | `platform/helmfile.yaml.gotmpl` | Create | Helmfile bootstrap: provider-gcp config, kagent, LGTM, OTel Collector, Kyverno, ArgoCD root-app | @ci-cd-specialist | 4 |
| 26 | `platform/argocd/bootstrap/root-app.yaml` | Create | ArgoCD `Application` watching `platform/argocd/applications/` in Gitea | @ci-cd-specialist | 25 |
| 27 | `platform/argocd/applications/observability.yaml` | Create | ArgoCD App for LGTM + OTel Collector + dashboards | @observability-engineer | 26 |
| 28 | `platform/argocd/applications/kagent.yaml` | Create | ArgoCD App for kagent controller chart | @k8s-platform-engineer | 26 |
| 29 | `platform/argocd/applications/crossplane-providers.yaml` | Create | ArgoCD App for provider-gcp + ProviderConfig referencing the SOPS-decrypted bootstrap-SA secret | @k8s-platform-engineer | 26 |
| 30 | `platform/argocd/applications/kyverno.yaml` | Create | ArgoCD App for Kyverno + project policy bundle | @k8s-platform-engineer | 26 |
| 31 | `platform/argocd/applications/sandbox.yaml` | Create | ArgoCD App for the Sandbox service Helm chart | @k8s-platform-engineer | 26 |
| 32 | `platform/argocd/applications/agent-prompts.yaml` | Create | ArgoCD App for shared prompt ConfigMaps Helm chart (DD-11) | @k8s-platform-engineer | 26 |
| 33 | `platform/argocd/applications/budget-controller.yaml` | Create | ArgoCD App for the budget-controller Helm chart (DD-10) | @k8s-platform-engineer | 26 |
| 34 | `platform/argocd/applications/platform-bootstrap-job.yaml` | Create | ArgoCD App for the one-shot bootstrap Job (DD-3); sync wave 5 (after Crossplane providers ready) | @k8s-platform-engineer | 26 |
| 35 | `platform/argocd/applications/agents.yaml` | Create | ArgoCD App watching `agents/` directory in Gitea (where Backstage template commits) | @k8s-platform-engineer | 26 |

### 4.5 Platform-local Helm charts

| # | File | Action | Purpose | Agent | Dependencies |
|---|------|--------|---------|-------|--------------|
| 36 | `platform/helm/sandbox/Chart.yaml` | Create | Chart metadata for Sandbox service | @k8s-platform-engineer | 25 |
| 37 | `platform/helm/sandbox/values.yaml` | Create | Image, resources (requests/limits including 3GB memory cap; cf. DD-8), pool size (1-2), service config | @k8s-platform-engineer | 36 |
| 38 | `platform/helm/sandbox/templates/deployment.yaml` | Create | Deployment with `runAsNonRoot`, `readOnlyRootFilesystem`, `/tmp` emptyDir, no SA token mount | @k8s-platform-engineer | 37 |
| 39 | `platform/helm/sandbox/templates/service.yaml` | Create | ClusterIP Service for the pool | @k8s-platform-engineer | 38 |
| 40 | `platform/helm/sandbox/templates/networkpolicy.yaml` | Create | Default-deny + allow egress to GCS endpoints + DNS only | @k8s-platform-engineer | 38 |
| 41 | `platform/helm/sandbox/templates/poddisruptionbudget.yaml` | Create | minAvailable: 1 for the pool | @k8s-platform-engineer | 38 |
| 42 | `platform/helm/chat-frontend/Chart.yaml` | Create | Chart metadata; *deployed per-agent by Backstage template* | @k8s-platform-engineer | 25 |
| 43 | `platform/helm/chat-frontend/values.yaml` | Create | Image, env (PLANNER_URL, AGENT_ID), resources, ingress hostname placeholder | @k8s-platform-engineer | 42 |
| 44 | `platform/helm/chat-frontend/templates/{deployment,service,ingress}.yaml` | Create | Standard Deployment/Service/Ingress (Ingress hostname is `{{ .Values.agentId }}.{{ .Values.baseDomain }}`) | @k8s-platform-engineer | 43 |
| 45 | `platform/helm/kyverno-policies/Chart.yaml` | Create | Chart metadata for project policy bundle | @kb-architect | 25 |
| 46 | `platform/helm/kyverno-policies/templates/require-resource-limits.yaml` | Create | Enforce CPU/memory limits in agent namespaces | @kb-architect | 45 |
| 47 | `platform/helm/kyverno-policies/templates/disallow-privileged.yaml` | Create | Block `privileged: true`, host namespaces | @kb-architect | 45 |
| 48 | `platform/helm/kyverno-policies/templates/restrict-image-registries.yaml` | Create | Allowlist: Gitea registry + pinned upstream registries | @kb-architect | 45 |
| 49 | `platform/helm/kyverno-policies/templates/agent-egress-allowlist.yaml` | Create | Generate NetworkPolicy template for every `agent-*` namespace | @kb-architect | 45 |
| 50 | `platform/helm/kyverno-policies/templates/sandbox-isolation.yaml` | Create | Stricter NetworkPolicy on `sandbox` namespace (egress only to GCS + DNS) | @kb-architect | 45 |
| 51 | `platform/helm/kyverno-policies/templates/require-budget-annotation.yaml` | Create | Audit policy: every Agent CRD must carry a `whisperops.io/budget-usd` annotation | @kb-architect | 45 |
| 52 | `platform/helm/observability-extras/Chart.yaml` | Create | Chart metadata | @observability-engineer | 25 |
| 53 | `platform/helm/observability-extras/values.yaml` | Create | OTel Collector config (DD-6: Tempo + Langfuse exporters), Grafana datasources (Tempo, Loki, Mimir, Infinity), dashboard provisioning | @observability-engineer | 52 |
| 54 | `platform/helm/observability-extras/templates/otel-collector-config.yaml` | Create | OTel Collector ConfigMap with the dual-exporter pipeline | @observability-engineer | 53 |
| 55 | `platform/helm/observability-extras/templates/grafana-dashboards.yaml` | Create | ConfigMap-based dashboard provisioning, references files from `platform/observability/dashboards/` | @observability-engineer | 53 |
| 56 | `platform/helm/observability-extras/templates/prometheus-rules.yaml` | Create | Recording + alerting rules (budget-burn, SLO multi-window-multi-burn-rate) | @observability-engineer | 53 |
| 57 | `platform/helm/agent-prompts/Chart.yaml` | Create | Chart metadata for shared agent prompts (DD-11) | @genai-architect | 25 |
| 58 | `platform/helm/agent-prompts/values.yaml` | Create | Optional prompt overrides | @genai-architect | 57 |
| 59 | `platform/helm/agent-prompts/files/prompt-planner.txt` | Create | Planner system prompt: routing/decomposition; consumes user question + dataset profile; emits structured plan | @genai-architect | 57 |
| 60 | `platform/helm/agent-prompts/files/prompt-analyst.txt` | Create | Analyst system prompt: code-gen for pandas/numpy/scipy/sklearn/matplotlib/plotly; calls `sandbox.execute_python` MCP tool | @genai-architect | 57 |
| 61 | `platform/helm/agent-prompts/files/prompt-writer.txt` | Create | Writer system prompt: didactic prose; embeds chart URL; shows code | @genai-architect | 57 |
| 62 | `platform/helm/agent-prompts/templates/configmap-planner.yaml` | Create | ConfigMap from `prompt-planner.txt` | @genai-architect | 59 |
| 63 | `platform/helm/agent-prompts/templates/configmap-analyst.yaml` | Create | ConfigMap from `prompt-analyst.txt` | @genai-architect | 60 |
| 64 | `platform/helm/agent-prompts/templates/configmap-writer.yaml` | Create | ConfigMap from `prompt-writer.txt` | @genai-architect | 61 |
| 65 | `platform/helm/budget-controller/Chart.yaml` | Create | Chart metadata for budget controller (DD-10) | @python-developer | 25 |
| 66 | `platform/helm/budget-controller/values.yaml` | Create | Image, resources, poll interval (60s), Langfuse credentials Secret reference | @python-developer | 65 |
| 67 | `platform/helm/budget-controller/templates/{deployment,serviceaccount,rbac}.yaml` | Create | Deployment + SA + RBAC (read kagent Agent CRDs, patch Deployments in agent namespaces, emit Events) | @python-developer | 66 |
| 68 | `platform/helm/platform-bootstrap-job/Chart.yaml` | Create | Chart metadata for the one-shot bootstrap Job (DD-3) | @python-developer | 25 |
| 69 | `platform/helm/platform-bootstrap-job/values.yaml` | Create | Image, resources, env (Supabase, Anthropic, OpenAI from ESO-synced secrets), datasets bucket name | @python-developer | 68 |
| 70 | `platform/helm/platform-bootstrap-job/templates/{job,serviceaccount,rbac}.yaml` | Create | Job (with sync-wave annotation), SA, RBAC (read shared bucket, write to Supabase) | @python-developer | 69 |

### 4.6 Crossplane Compositions and provider config

| # | File | Action | Purpose | Agent | Dependencies |
|---|------|--------|---------|-------|--------------|
| 71 | `platform/crossplane/provider-gcp.yaml` | Create | `Provider` CR for `provider-gcp` | @k8s-platform-engineer | 29 |
| 72 | `platform/crossplane/provider-config.yaml` | Create | `ProviderConfig` referencing the bootstrap-SA Secret synced by ESO | @k8s-platform-engineer | 71 |
| 73 | `platform/crossplane/external-secret-bootstrap.yaml` | Create | ESO `ExternalSecret` for the SOPS-decrypted bootstrap SA JSON key → in-cluster Secret consumed by ProviderConfig | @k8s-platform-engineer | 72 |

### 4.7 Backstage template — Dataset Whisperer

| # | File | Action | Purpose | Agent | Dependencies |
|---|------|--------|---------|-------|--------------|
| 74 | `backstage-templates/dataset-whisperer/template.yaml` | Create | 4-field form (name with regex validation, description, dataset dropdown, model dropdown); steps: generate-suffix → fetch:template → publish:gitea → register:catalog | @ci-cd-specialist | 25 |
| 75 | `backstage-templates/dataset-whisperer/actions/generate-suffix.ts` | Create | Custom scaffolder action `whisperops:generate-suffix` (DD-4) | @typescript-developer | 74 |
| 76 | `backstage-templates/dataset-whisperer/actions/index.ts` | Create | Action registration export | @typescript-developer | 75 |
| 77 | `backstage-templates/dataset-whisperer/skeleton/namespace.yaml.njk` | Create | K8s Namespace `agent-{{ values.agent_name }}-{{ parameters.suffix }}` | @ci-cd-specialist | 74 |
| 78 | `backstage-templates/dataset-whisperer/skeleton/bucket.yaml.njk` | Create | Crossplane `Bucket` for per-agent bucket | @k8s-platform-engineer | 74 |
| 79 | `backstage-templates/dataset-whisperer/skeleton/service-account.yaml.njk` | Create | Crossplane `ServiceAccount` (provider-gcp) | @k8s-platform-engineer | 74 |
| 80 | `backstage-templates/dataset-whisperer/skeleton/service-account-key.yaml.njk` | Create | Crossplane `ServiceAccountKey` materializing a K8s Secret in the agent namespace | @k8s-platform-engineer | 74 |
| 81 | `backstage-templates/dataset-whisperer/skeleton/iam-bindings.yaml.njk` | Create | Crossplane `IAMMember` ×2: `roles/storage.objectViewer` on shared datasets bucket; `roles/storage.objectAdmin` on per-agent bucket (DEFINE D-005) | @k8s-platform-engineer | 74 |
| 82 | `backstage-templates/dataset-whisperer/skeleton/agent-planner.yaml.njk` | Create | kagent Agent CRD: model=`claude-haiku-4-5-20251001` (fixed; cf. system context), `systemPromptConfigMapRef: prompt-planner` | @genai-architect | 74 |
| 83 | `backstage-templates/dataset-whisperer/skeleton/agent-analyst.yaml.njk` | Create | kagent Agent CRD: model from form (`{{ values.primary_model }}`), prompt-analyst, MCP tool ref `sandbox.execute_python` | @genai-architect | 74 |
| 84 | `backstage-templates/dataset-whisperer/skeleton/agent-writer.yaml.njk` | Create | kagent Agent CRD: model from form, prompt-writer | @genai-architect | 74 |
| 85 | `backstage-templates/dataset-whisperer/skeleton/toolserver-sandbox.yaml.njk` | Create | kagent `ToolServer` CRD pointing at the shared Sandbox service in the `sandbox` namespace | @genai-architect | 74 |
| 86 | `backstage-templates/dataset-whisperer/skeleton/kyverno-policy.yaml.njk` | Create | Per-agent Kyverno `Policy` (namespace-scoped) — pins agent-specific egress allowlist | @kb-architect | 74 |
| 87 | `backstage-templates/dataset-whisperer/skeleton/chat-frontend.yaml.njk` | Create | HelmRelease (or rendered Deployment+Service) for the chat-frontend chart, with agent-specific values | @ci-cd-specialist | 74 |
| 88 | `backstage-templates/dataset-whisperer/skeleton/ingress.yaml.njk` | Create | Ingress with hostname `agent-{{ values.agent_name }}-{{ parameters.suffix }}.{{ values.base_domain }}` | @ci-cd-specialist | 74 |
| 89 | `backstage-templates/dataset-whisperer/skeleton/argocd-app.yaml.njk` | Create | ArgoCD `Application` watching `agents/{name}-{xyz}/` directory in Gitea | @ci-cd-specialist | 74 |
| 90 | `backstage-templates/dataset-whisperer/skeleton/external-secret.yaml.njk` | Create | ESO `ExternalSecret` to sync per-agent SA key from Crossplane-produced Secret into mountable form | @ci-cd-specialist | 74 |
| 91 | `backstage-templates/dataset-whisperer/README.md` | Create | Operator-facing template docs | @code-documenter | 74 |

### 4.8 Source code — Sandbox

| # | File | Action | Purpose | Agent | Dependencies |
|---|------|--------|---------|-------|--------------|
| 92 | `src/sandbox/pyproject.toml` | Create | Python 3.12; pinned: fastapi, uvicorn, pydantic, google-cloud-storage, opentelemetry-{api,sdk,instrumentation-fastapi}; whitelisted runtime libs are bundled in image (not pip-installed at runtime) | @python-developer | 4 |
| 93 | `src/sandbox/Dockerfile` | Create | Python 3.12-slim base; bake whitelisted libs (pandas, numpy, scipy, scikit-learn, matplotlib, seaborn, plotly); `pip install` blocked at runtime via removing pip from image after build | @python-developer | 92 |
| 94 | `src/sandbox/app/main.py` | Create | FastAPI app: `POST /execute`, `GET /healthz`; OTel auto-instrumentation; structured JSON logging | @python-developer | 92 |
| 95 | `src/sandbox/app/schemas.py` | Create | Pydantic models: `ExecuteRequest`, `ExecuteResponse`; explicit fields for code, dataset_id, sa_key_b64, agent_id | @python-developer | 92 |
| 96 | `src/sandbox/app/execution.py` | Create | Subprocess executor: 60s timeout, 3GB memory cgroup (via `prlimit`/`setrlimit`), reads dataset signed URL, runs code in isolated subprocess, captures stdout/stderr/artifacts | @python-developer | 95 |
| 97 | `src/sandbox/app/credentials.py` | Create | Per-execution credential injection: writes SA key to `/tmp/cred-{uuid}.json`, sets `GOOGLE_APPLICATION_CREDENTIALS` for subprocess only, deletes file in `finally` | @python-developer | 95 |
| 98 | `src/sandbox/app/artifact_upload.py` | Create | Upload `/tmp/*.png` and `/tmp/*.html` to per-agent bucket; mint signed URL (15-min expiry); return URL | @python-developer | 96, 97 |
| 99 | `src/sandbox/app/observability.py` | Create | OTel setup; structured logger; per-execution span with attributes (agent_id, dataset_id, exit_code) | @python-developer | 92 |
| 100 | `src/sandbox/tests/test_execution.py` | Create | Unit: timeout enforcement, OOM enforcement, artifact upload | @test-generator | 96 |
| 101 | `src/sandbox/tests/test_credentials.py` | Create | Unit: cred file lifetime; verify `finally` cleanup | @test-generator | 97 |
| 102 | `src/sandbox/tests/test_main.py` | Create | Integration: FastAPI TestClient hitting `/execute` with happy path + adversarial cases | @test-generator | 94 |

### 4.9 Source code — Chat frontend

| # | File | Action | Purpose | Agent | Dependencies |
|---|------|--------|---------|-------|--------------|
| 103 | `src/chat-frontend/package.json` | Create | Pinned: next 15.x, react 19.x, typescript 5.x, tailwindcss 4.x, @opentelemetry/sdk-trace-web | @typescript-developer | 4 |
| 104 | `src/chat-frontend/Dockerfile` | Create | Multi-stage: build → distroless runtime; non-root user | @typescript-developer | 103 |
| 105 | `src/chat-frontend/next.config.ts` | Create | Output: `standalone`; no telemetry to Vercel | @typescript-developer | 103 |
| 106 | `src/chat-frontend/app/page.tsx` | Create | Main chat page: input box, message list, dark-mode toggle | @frontend-architect | 103 |
| 107 | `src/chat-frontend/app/api/chat/route.ts` | Create | SSE proxy: receives POST from browser, opens HTTP stream to Planner agent at `${PLANNER_URL}`, pipes SSE-formatted chunks back (DD-5) | @frontend-architect | 103 |
| 108 | `src/chat-frontend/app/components/Message.tsx` | Create | Renders markdown message; embeds `<ChartEmbed>` and `<CodeBlock>` | @frontend-architect | 103 |
| 109 | `src/chat-frontend/app/components/ChartEmbed.tsx` | Create | `<img>` for PNG signed URLs; `<iframe>` for Plotly HTML | @frontend-architect | 103 |
| 110 | `src/chat-frontend/app/components/CodeBlock.tsx` | Create | Syntax-highlighted code block (Shiki or similar) | @frontend-architect | 103 |
| 111 | `src/chat-frontend/lib/sse.ts` | Create | Browser-side `EventSource` wrapper with reconnect | @frontend-architect | 103 |
| 112 | `src/chat-frontend/lib/observability.ts` | Create | Browser OTel SDK init; OTLP-HTTP to in-cluster Collector | @observability-engineer | 103 |

### 4.10 Source code — Platform bootstrap

| # | File | Action | Purpose | Agent | Dependencies |
|---|------|--------|---------|-------|--------------|
| 113 | `src/platform-bootstrap/pyproject.toml` | Create | Python 3.12; anthropic, openai, supabase, google-cloud-storage, pandas, numpy, pydantic | @python-developer | 4 |
| 114 | `src/platform-bootstrap/Dockerfile` | Create | Python 3.12-slim; non-root | @python-developer | 113 |
| 115 | `src/platform-bootstrap/bootstrap.py` | Create | Main: read CSVs from shared bucket → generate profile JSON (schema, dtype, ranges, top categoricals, missing-rate) → embed profile description with OpenAI → write to Supabase pgvector; idempotent via `source_hash` check (DD-3) | @extraction-specialist | 113 |
| 116 | `src/platform-bootstrap/profile_schema.py` | Create | Pydantic model for `DatasetProfile` — the Planner's primary input shape | @extraction-specialist | 113 |
| 117 | `src/platform-bootstrap/profiles/california-housing.json` | Create | (May be empty placeholder — bootstrap pod generates and optionally commits) | @extraction-specialist | 116 |
| 118 | `src/platform-bootstrap/profiles/online-retail-ii.json` | Create | (May be empty placeholder) | @extraction-specialist | 116 |
| 119 | `src/platform-bootstrap/profiles/spotify-tracks.json` | Create | (May be empty placeholder) | @extraction-specialist | 116 |
| 120 | `src/platform-bootstrap/tests/test_profile_generation.py` | Create | Unit + integration tests with sample DataFrames | @test-generator | 115 |

### 4.11 Source code — Budget controller

| # | File | Action | Purpose | Agent | Dependencies |
|---|------|--------|---------|-------|--------------|
| 121 | `src/budget-controller/pyproject.toml` | Create | Python 3.12; kubernetes, httpx, pydantic, opentelemetry-api | @python-developer | 4 |
| 122 | `src/budget-controller/Dockerfile` | Create | Python 3.12-slim; non-root | @python-developer | 121 |
| 123 | `src/budget-controller/main.py` | Create | Loop: 60s poll Langfuse REST → for each Agent CRD with budget annotation, compute usage → at 80% emit Event + Prom counter → at 100% patch Deployments to replicas:0 (DD-10) | @python-developer | 121 |
| 124 | `src/budget-controller/tests/test_main.py` | Create | Unit tests with mocked Langfuse + fake K8s API | @test-generator | 123 |

### 4.12 Observability assets

| # | File | Action | Purpose | Agent | Dependencies |
|---|------|--------|---------|-------|--------------|
| 125 | `platform/observability/dashboards/platform-health.json` | Create | Cluster CPU/memory, ArgoCD sync status, Crossplane reconcile status, NGINX p50/p95/p99, cert expiry | @observability-engineer | 53 |
| 126 | `platform/observability/dashboards/agent-cost.json` | Create | Total LLM cost (Infinity → Langfuse), top-10 expensive agents, per-query distribution, budget burn | @observability-engineer | 53 |
| 127 | `platform/observability/dashboards/agent-performance.json` | Create | Per-agent p50/p95/p99 query latency, A2A hop breakdown, error rate by type | @observability-engineer | 53 |
| 128 | `platform/observability/dashboards/sandbox-execution.json` | Create | Concurrent execs, queue depth, timeout rate, OOM rate, top-10 imports, upload latency | @observability-engineer | 53 |
| 129 | `platform/observability/alerts/platform-slos.yaml` | Create | Multi-window-multi-burn-rate alert rules for query-latency SLO | @observability-engineer | 56 |
| 130 | `platform/observability/alerts/budget-burn.yaml` | Create | Per-agent 80% / 100% budget alert rules (consumed by budget-controller too) | @observability-engineer | 56 |

### 4.13 Tests — smoke + eval

| # | File | Action | Purpose | Agent | Dependencies |
|---|------|--------|---------|-------|--------------|
| 131 | `tests/smoke/platform-up.sh` | Create | After `make deploy`: assert all 8 surfaces reachable, all ArgoCD apps Synced/Healthy, all Crossplane resources Ready | @ci-cd-specialist | 4 |
| 132 | `tests/smoke/agent-creation.sh` | Create | Programmatically POST a Backstage template submission via the API; assert PR opens, merges, agent reachable in ≤ 90s | @ci-cd-specialist | 131 |
| 133 | `tests/smoke/query-roundtrip.sh` | Create | Hit each agent's chat endpoint with a fixed question; assert response shape (text + chart URL + code block) within 30s | @ci-cd-specialist | 132 |
| 134 | `tests/eval/agent-template-validation/run-evals.py` | Create | CI smoke eval entry point: validate manifests against schemas, run a fixed test query against a mocked Crossplane environment | @python-developer | 4 |
| 135 | `tests/eval/agent-template-validation/fixtures/california-housing.json` | Create | Test question + expected response shape | @python-developer | 134 |
| 136 | `tests/eval/agent-template-validation/fixtures/online-retail-ii.json` | Create | Test question + expected response shape | @python-developer | 134 |
| 137 | `tests/eval/agent-template-validation/fixtures/spotify-tracks.json` | Create | Test question + expected response shape | @python-developer | 134 |

### 4.14 CI

| # | File | Action | Purpose | Agent | Dependencies |
|---|------|--------|---------|-------|--------------|
| 138 | `.github/workflows/ci.yml` | Create | Lint Python, TS, Helm; Terraform validate; SOPS-required-files check (DEFINE D-007) | @ci-cd-specialist | 4 |
| 139 | `.github/workflows/agent-eval.yml` | Create | On PRs touching `agents/**`: spin ephemeral kind, apply manifests with mocked Crossplane, run smoke eval | @ci-cd-specialist | 134 |
| 140 | `.github/workflows/release.yml` | Create | On `main` push: build + push Docker images for sandbox, chat-frontend, platform-bootstrap, budget-controller (image tags = git short-sha) | @ci-cd-specialist | 4 |

### 4.15 Documentation

| # | File | Action | Purpose | Agent | Dependencies |
|---|------|--------|---------|-------|--------------|
| 141 | `docs/DEPLOYMENT.md` | Create | Step-by-step deploy, including dataset upload step (DEFINE D-004) | @code-documenter | 3 |
| 142 | `docs/ARCHITECTURE.md` | Create | Component diagrams, data flows (mirrors §1 of this DESIGN) | @code-documenter | 3 |
| 143 | `docs/OBSERVABILITY.md` | Create | Dashboard walkthrough, trace examples, query patterns | @code-documenter | 125-128 |
| 144 | `docs/SECURITY.md` | Create | Threat model, controls, residual risks (mirrors source plan §8) | @code-documenter | 3 |
| 145 | `docs/runbooks/platform-bootstrap.md` | Create | What to do when `make deploy` fails at each stage | @code-documenter | 3 |
| 146 | `docs/runbooks/agent-creation.md` | Create | What to do when a Backstage submission fails | @code-documenter | 3 |
| 147 | `docs/runbooks/incident-response.md` | Create | Budget breach, sandbox failures, Crossplane stuck reconciling | @code-documenter | 3 |

**Total Files: 147** (plus `git init` step #0).

---

## 5. Agent Assignment Rationale

| Agent | Files Assigned | Why This Agent |
|-------|----------------|----------------|
| **@infra-deployer** | 5–19 (Terraform: 15 files) | GCP Terraform modules, GCS state backend, IAM scoping with conditions — exact fit |
| **@k8s-platform-engineer** | 28–34, 36–50, 71–73, 78–81, 86 (Helm charts, ArgoCD apps, Crossplane CRDs/Compositions, Kyverno policies — ~30 files) | Kubernetes-native authoring (Helm, ArgoCD, Crossplane) — primary specialist |
| **@observability-engineer** | 27, 52–56, 112, 125–130 (LGTM, OTel Collector, dashboards, alerts, browser OTel — ~13 files) | OTel + Grafana + Prometheus rules + SLOs — exact fit |
| **@ci-cd-specialist** | 4, 25, 26, 35, 74, 87–89, 131–133, 138–140 (Makefile, ArgoCD root, Backstage template, smoke tests, GitHub Actions — ~14 files) | DevOps automation, GitOps wiring, CI pipelines |
| **@python-developer** | 65–70, 92–102, 113–115, 121–124 (Sandbox FastAPI, budget-controller, helm charts for both, tests — ~22 files) | Python service authoring, subprocess management, K8s API client |
| **@typescript-developer** | 75–76, 103–105 (Backstage scaffolder action, Next.js config — 5 files) | TypeScript-only files |
| **@frontend-architect** | 106–111 (Next.js page, components, SSE client — 6 files) | React + SPA + SSE; chat UI design |
| **@genai-architect** | 57–64, 82–85 (agent prompts ConfigMaps + kagent Agent CRDs — 12 files) | Multi-agent A2A design, prompt structure for distinct cognitive roles |
| **@extraction-specialist** | 115–120 (platform-bootstrap profile generator — 6 files) | Pydantic + structured extraction over CSVs |
| **@kb-architect** | 45–51, 86 (Kyverno policy bundle — 8 files) | Authoring policy bundles is its specialty |
| **@code-documenter** | 3, 91, 141–147 (README, template README, docs/, runbooks — 9 files) | Documentation specialist |
| **@test-generator** | 100, 101, 102, 120, 124 (5 test files) | Pytest fixtures, edge cases |
| **(general / manual)** | 0, 1, 2, 18–24 (git init, gitignore, sops, secrets values) | Operator-driven setup steps |

**Agent Discovery:** Scanned `.claude/agents/`. 13 specialists matched; 4 general-purpose steps remain for the operator (git init, secrets value entry).

---

## 6. Code Patterns

### Pattern 1: Sandbox `/execute` handler

```python
# src/sandbox/app/main.py — the entry point
from fastapi import FastAPI, HTTPException
from .schemas import ExecuteRequest, ExecuteResponse
from .execution import run_in_subprocess
from .credentials import scoped_credentials
from .artifact_upload import upload_artifacts
from .observability import tracer, logger

app = FastAPI()

@app.post("/execute", response_model=ExecuteResponse)
async def execute(req: ExecuteRequest) -> ExecuteResponse:
    with tracer.start_as_current_span("sandbox.execute") as span:
        span.set_attribute("agent.id", req.agent_id)
        span.set_attribute("dataset.id", req.dataset_id)
        with scoped_credentials(req.sa_key_b64) as cred_path:
            result = run_in_subprocess(
                code=req.code,
                cred_path=cred_path,
                dataset_signed_url=req.dataset_signed_url,
                timeout_s=60,
                memory_bytes=3 * 1024**3,
            )
            chart_url = upload_artifacts(
                tmp_dir=result.tmp_dir,
                bucket=req.agent_bucket,
                cred_path=cred_path,
            ) if result.exit_code == 0 else None
            return ExecuteResponse(
                stdout=result.stdout,
                stderr=result.stderr,
                exit_code=result.exit_code,
                chart_url=chart_url,
                error=result.error,
            )
```

### Pattern 2: Per-execution credential lifecycle

```python
# src/sandbox/app/credentials.py
from contextlib import contextmanager
from pathlib import Path
from tempfile import NamedTemporaryFile
import base64, os

@contextmanager
def scoped_credentials(sa_key_b64: str):
    """Write SA key to tmp file, yield path, ALWAYS delete on exit."""
    fd = NamedTemporaryFile(mode="wb", suffix=".json", delete=False)
    try:
        fd.write(base64.b64decode(sa_key_b64))
        fd.close()
        os.chmod(fd.name, 0o600)
        yield fd.name
    finally:
        Path(fd.name).unlink(missing_ok=True)
```

### Pattern 3: Subprocess with cgroup limits

```python
# src/sandbox/app/execution.py
import subprocess, resource, tempfile, os
from dataclasses import dataclass

@dataclass
class ExecResult:
    stdout: str; stderr: str; exit_code: int
    tmp_dir: str; error: str | None

def _setlimits(memory_bytes: int):
    resource.setrlimit(resource.RLIMIT_AS, (memory_bytes, memory_bytes))
    resource.setrlimit(resource.RLIMIT_CPU, (60, 60))

def run_in_subprocess(code: str, cred_path: str, dataset_signed_url: str,
                       timeout_s: int, memory_bytes: int) -> ExecResult:
    tmp = tempfile.mkdtemp(prefix="exec-")
    env = {
        "PATH": "/usr/local/bin:/usr/bin",
        "GOOGLE_APPLICATION_CREDENTIALS": cred_path,
        "DATASET_URL": dataset_signed_url,
        "OUT_DIR": tmp,
    }
    try:
        proc = subprocess.run(
            ["python", "-c", code],
            cwd=tmp, env=env,
            preexec_fn=lambda: _setlimits(memory_bytes),
            capture_output=True, text=True, timeout=timeout_s,
        )
        return ExecResult(proc.stdout, proc.stderr, proc.returncode, tmp, None)
    except subprocess.TimeoutExpired:
        return ExecResult("", "", -1, tmp, "timeout")
    except MemoryError:
        return ExecResult("", "", -1, tmp, "memory limit exceeded")
```

### Pattern 4: Backstage scaffolder custom action — generate-suffix

```typescript
// backstage-templates/dataset-whisperer/actions/generate-suffix.ts
import { createTemplateAction } from '@backstage/plugin-scaffolder-node';

const ALPHABET = 'abcdefghijklmnopqrstuvwxyz0123456789';

export const generateSuffixAction = () =>
  createTemplateAction<{ length?: number }>({
    id: 'whisperops:generate-suffix',
    schema: {
      input: { type: 'object', properties: { length: { type: 'number', default: 3 } } },
      output: { type: 'object', properties: { suffix: { type: 'string' } } },
    },
    async handler(ctx) {
      const len = ctx.input.length ?? 3;
      let s = '';
      for (let i = 0; i < len; i++) s += ALPHABET[Math.floor(Math.random() * ALPHABET.length)];
      ctx.output('suffix', s);
    },
  });
```

### Pattern 5: kagent Agent CRD (Analyst, with model from form)

```yaml
# backstage-templates/dataset-whisperer/skeleton/agent-analyst.yaml.njk
apiVersion: kagent.dev/v1
kind: Agent
metadata:
  name: analyst
  namespace: agent-{{ values.agent_name }}-{{ parameters.suffix }}
  annotations:
    whisperops.io/budget-usd: "{{ values.budget_usd | default('5.00') }}"
spec:
  model:
    provider: anthropic
    modelId: {{ values.primary_model }}   # e.g., claude-sonnet-4-6 or claude-haiku-4-5-20251001
  systemPromptConfigMapRef:
    name: prompt-analyst
    namespace: whisperops-system
  tools:
    - name: sandbox.execute_python
      toolServer: sandbox
      toolServerNamespace: sandbox
  observability:
    otlpEndpoint: http://otel-collector.observability:4317
    tags:
      - agent-{{ values.agent_name }}-{{ parameters.suffix }}
      - dataset:{{ values.dataset_id }}
```

### Pattern 6: Crossplane Bucket + IAM (Backstage-templated)

```yaml
# backstage-templates/dataset-whisperer/skeleton/bucket.yaml.njk
apiVersion: storage.gcp.upbound.io/v1beta1
kind: Bucket
metadata:
  name: agent-{{ values.agent_name }}-{{ parameters.suffix }}
spec:
  forProvider:
    location: {{ values.region | default('US-CENTRAL1') }}
    publicAccessPrevention: enforced
    versioning:
      - enabled: true
  providerConfigRef:
    name: default
---
# iam-bindings.yaml.njk (excerpt)
apiVersion: cloudplatform.gcp.upbound.io/v1beta1
kind: ProjectIAMMember
metadata:
  name: agent-{{ values.agent_name }}-{{ parameters.suffix }}-datasets-viewer
spec:
  forProvider:
    role: roles/storage.objectViewer
    member: serviceAccount:agent-{{ values.agent_name }}-{{ parameters.suffix }}@{{ values.project_id }}.iam.gserviceaccount.com
    conditionExpression: |
      resource.name.startsWith("projects/_/buckets/{{ values.project_id }}-datasets")
```

### Pattern 7: Dataset profile schema (Pydantic)

```python
# src/platform-bootstrap/profile_schema.py
from pydantic import BaseModel, Field
from typing import Literal

class ColumnProfile(BaseModel):
    name: str
    dtype: Literal["int64","float64","object","datetime64[ns]","bool","category"]
    null_rate: float = Field(ge=0, le=1)
    n_unique: int
    sample_values: list[str] = Field(max_length=10)
    min: float | None = None
    max: float | None = None
    mean: float | None = None

class DatasetProfile(BaseModel):
    dataset_id: Literal["california-housing","online-retail-ii","spotify-tracks"]
    csv_filename: str  # e.g., "california-housing-prices.csv" — flat bucket key
    n_rows: int
    n_cols: int
    columns: list[ColumnProfile]
    archetype: Literal["regression","time-series","exploratory"]
    description: str  # human-readable; embedded for pgvector
    source_hash: str  # sha256 of CSV; idempotency key for DD-3
```

### Pattern 8: OTel Collector dual-exporter pipeline

```yaml
# platform/helm/observability-extras/values.yaml (excerpt)
otel-collector:
  config:
    receivers:
      otlp: { protocols: { grpc: {endpoint: 0.0.0.0:4317}, http: {endpoint: 0.0.0.0:4318} } }
    processors:
      batch: {}
      memory_limiter: { check_interval: 1s, limit_mib: 200 }
    exporters:
      otlp/tempo:
        endpoint: tempo.observability:4317
        tls: { insecure: true }
      otlphttp/langfuse:
        endpoint: ${LANGFUSE_OTLP_ENDPOINT}  # e.g., https://cloud.langfuse.com/api/public/otel
        headers:
          Authorization: "Basic ${LANGFUSE_BASIC_AUTH}"  # base64(public_key:secret_key)
    service:
      pipelines:
        traces:
          receivers: [otlp]
          processors: [memory_limiter, batch]
          exporters: [otlp/tempo, otlphttp/langfuse]
```

---

## 7. Data Flow

### 7.1 Provisioning a new agent (Backstage → working chat in ≤ 90 s)

```text
1. Operator fills 4-field Backstage form, clicks Submit
   │
   ▼
2. Scaffolder runs `whisperops:generate-suffix` action → suffix={xyz}
   │
   ▼
3. Scaffolder renders 14 .njk skeleton files into agents/{name}-{xyz}/
   │
   ▼
4. Scaffolder commits + opens PR against Gitea (`agents/{name}-{xyz}/`)
   │
   ▼
5. GitHub Actions agent-eval.yml runs (mock Crossplane, fixed test query); on pass, PR can merge
   │
   ▼
6. PR merged → ArgoCD detects new path under apps/agents → syncs in dependency order:
   sync-wave 0:  Namespace + ESO ExternalSecret
   sync-wave 1:  Crossplane Bucket + ServiceAccount + IAMMember + ServiceAccountKey
   sync-wave 2:  kagent Agent CRDs ×3 + ToolServer + Kyverno Policy
   sync-wave 3:  Chat-frontend Deployment + Service + Ingress
   │
   ▼
7. Crossplane reconciles cloud resources (~30-60s); ServiceAccountKey produces a K8s Secret
   │
   ▼
8. ESO syncs Secret into agent namespace; kagent controller reconciles Agents (≤ 10s)
   │
   ▼
9. NGINX Ingress + cert-manager pick up the new hostname; TLS issued via HTTP-01 (≤ 30s on cold)
   │
   ▼
10. Total: ~60-90s. Backstage catalog shows the new agent with chat URL.
```

### 7.2 Query at runtime (≤ 15 s p50)

```text
User types question in chat
  │
  ▼ HTTP POST /api/chat
Chat-frontend Next.js route handler
  │
  ▼ HTTP POST to Planner agent service
Planner (Haiku) reads dataset profile from in-memory cache (or pgvector miss);
  emits structured plan
  │
  ▼ A2A call
Analyst (Haiku/Sonnet) generates Python code, calls sandbox.execute_python MCP tool
  │
  ▼ HTTP POST /execute (sandbox service)
Sandbox: per-execution credential, subprocess with cgroup limits, runs code,
  uploads chart to per-agent bucket, returns signed URL + stdout
  │
  ▼ tool result back to Analyst
Analyst synthesizes factual summary
  │
  ▼ A2A call
Writer (Haiku/Sonnet) formats didactic prose, embeds chart URL, shows code,
  STREAMS tokens via SSE back through chat-frontend route handler
  │
  ▼ SSE stream
Browser EventSource renders tokens incrementally; chart renders inline once URL arrives
```

Every span at every step → OTel Collector → fan-out to Tempo (in-cluster) and Langfuse Cloud.

---

## 8. Integration Points

| External System | Integration Type | Authentication | Used By |
|-----------------|-----------------|----------------|---------|
| Anthropic API | HTTPS REST (kagent uses Anthropic SDK internally) | `ANTHROPIC_API_KEY` from SOPS → ESO → agent namespace Secret | Planner, Analyst, Writer |
| OpenAI API | HTTPS REST (only `text-embedding-3-small`) | `OPENAI_API_KEY` from SOPS → ESO → bootstrap-job namespace | platform-bootstrap |
| Supabase | HTTPS REST (supabase-py) | Service role key (write, bootstrap), anon key (read, agents) | platform-bootstrap (write); Planner (read) |
| Langfuse Cloud | OTLP-HTTP via Collector | Basic auth header (public_key:secret_key) | OTel Collector exporter |
| GCS | gRPC + HTTPS (google-cloud-storage) | Per-agent SA via mounted JSON key | Sandbox (write artifacts, read datasets) |
| Let's Encrypt | ACME HTTP-01 | n/a | cert-manager |
| sslip.io | DNS resolution only | n/a | Cluster ingress |
| GitHub Actions | (CI runner) | GitHub-issued `GITHUB_TOKEN`; for image push, pinned token | CI workflows |
| Gitea (in-cluster) | HTTPS Git | Initial credentials managed by idpBuilder; ArgoCD reads via Sealed Secret | Backstage publish, ArgoCD pull |

---

## 9. Testing Strategy

| Test Type | Scope | Files | Tools | Coverage Goal |
|-----------|-------|-------|-------|---------------|
| **Unit** | Sandbox handlers, credential lifecycle, profile-generation, budget-controller logic | `src/*/tests/test_*.py` | pytest | 80% line coverage |
| **Integration (in-process)** | FastAPI TestClient on Sandbox; pgvector against a local Postgres in CI | `src/sandbox/tests/test_main.py`, `src/platform-bootstrap/tests/*` | pytest + testcontainers (Postgres) | All happy paths + 3 adversarial cases |
| **CI smoke eval** | Per-agent template validation: schema check + 1 fixed query per dataset, mocked Crossplane | `tests/eval/agent-template-validation/run-evals.py` | GitHub Actions + ephemeral kind | Block PR on failure |
| **Smoke (post-deploy)** | All surfaces reachable, ArgoCD healthy, Crossplane reconciled, end-to-end agent-creation + query | `tests/smoke/*.sh` | bash + kubectl + curl | All MUST acceptance tests pass |
| **Memory spike (Day 1 of /build)** | Online Retail II groupby+merge+pivot peak RSS in actual sandbox cgroup | Ad-hoc script under `tests/spike/` | pytest + `psutil` | Decide DD-8's mitigation path |
| **Adversarial sandbox** | Network egress, OOM, timeout, runaway loop | `tests/adversarial/*` | pytest | All denials work as designed (AT-009, AT-012) |

---

## 10. Error Handling

| Error Type | Handling Strategy | Retry? |
|------------|-------------------|--------|
| Anthropic rate-limit (429) | kagent retries with exponential backoff; surface to user as "Service busy, retry" after 3 attempts | Yes (3, exp) |
| Sandbox subprocess timeout (60s) | Return `{exit_code: -1, error: "timeout"}` to Analyst; Analyst's prompt instructs it to apologize and suggest a narrower query | No |
| Sandbox OOM | Same as timeout; error: "memory limit exceeded" | No |
| Sandbox network egress denied | Subprocess sees connection refused; surface in stderr; trace records the violation | No |
| Crossplane provisioning failure | Stays in `Pending` indefinitely; ArgoCD shows Degraded; runbook has the SA-permission diagnostic flow | Yes (manual) |
| Langfuse API down | OTel Collector batches and retries; falls back to dropping spans after 5min; LGTM still has full trace | Yes (collector default) |
| Agent budget breach (100%) | budget-controller scales Deployments to 0; chat returns 503; alert fires | No (manual reset) |
| Dataset bucket missing CSV (operator forgot to upload) | Sandbox returns `{exit_code: -1, error: "dataset not found at gs://..."}`; Analyst's prompt converts this into a polite "this dataset is not available yet" | No |
| Backstage scaffolder action error (suffix collision in 36³ space) | Action retries up to 3 times before failing the whole template flow | Yes (3) |
| Cert-manager HTTP-01 challenge fails | NGINX ingress serves with self-signed; runbook for Let's Encrypt rate-limit | Yes (manual) |
| ArgoCD sync stuck | Watch for `OutOfSync` > 5min via Prometheus alert | Yes (auto-retry) |

---

## 11. Configuration

| Config Key | Type | Default | Description | Where set |
|------------|------|---------|-------------|-----------|
| `project_id` | string | (none, required) | GCP project | `terraform/envs/demo/terraform.tfvars` |
| `region` | string | `us-central1` | GCP region | `terraform/envs/demo/terraform.tfvars` |
| `vm_machine_type` | string | `e2-standard-8` | VM type | `terraform/envs/demo/terraform.tfvars` |
| `allowed_ssh_cidr` | string | (none, required) | Operator's IP for SSH access | `terraform/envs/demo/terraform.tfvars` |
| `base_domain` | string | computed `{IP}.sslip.io` | Wildcard domain | computed in TF + passed to platform |
| `sandbox.memory_limit_bytes` | int | `3221225472` (3 GB) | Per-execution memory cap | `platform/helm/sandbox/values.yaml` (DD-8) |
| `sandbox.timeout_seconds` | int | `60` | Per-execution wall-clock cap | `platform/helm/sandbox/values.yaml` |
| `sandbox.pool_size` | int | `2` | Pre-warmed pod count | `platform/helm/sandbox/values.yaml` |
| `budget_controller.poll_interval_seconds` | int | `60` | How often to poll Langfuse | `platform/helm/budget-controller/values.yaml` |
| `budget_controller.warn_threshold` | float | `0.80` | 80% alert | (same) |
| `budget_controller.kill_threshold` | float | `1.00` | 100% scale-to-zero | (same) |
| `agent.budget_usd` | string | `"5.00"` | Per-agent budget annotation | Backstage form (hidden, default; could become field 5 in future) |
| `agent.primary_model` | string | (form input) | `claude-haiku-4-5-20251001` or `claude-sonnet-4-6` | Backstage form |
| `agent.dataset_id` | string | (form input) | `california-housing` / `online-retail-ii` / `spotify-tracks` | Backstage form |

---

## 12. Phasing recommendation (for /build)

The DESIGN doc declares the full target shape. /build should sequence work in stages so that the **memory-spike validation** (DD-8) and the **end-to-end agent-creation flow** are reached as early as possible — before deep investment in observability extras and policy bundle. Suggested order:

```text
Stage 0 — Pre-flight (≤ 0.5 day)
  files 0–4 (git init, .gitignore, .sops.yaml, README skeleton, Makefile skeleton)

Stage 1 — Cloud floor (≤ 1 day)
  files 5–24 (Terraform; secrets placeholder); `terraform apply` works; bucket exists; bootstrap SA exists
  ↳ ACCEPTANCE: AT-002 partial (bucket reachable; manual upload works)

Stage 2 — Memory spike (≤ 0.5 day)
  Ad-hoc test from tests/spike/. Run Online Retail II groupby+merge+pivot in a sandbox-shaped pod.
  Decide DD-8's mitigation path. Lock final memory limit value.

Stage 3 — Sandbox service standalone (≤ 1.5 days)
  files 92–102 + 36–41 (Sandbox app, Helm chart, NetworkPolicy)
  Deployable to kind directly; tests pass
  ↳ ACCEPTANCE: AT-005, AT-009, AT-012

Stage 4 — IDP bootstrap on the VM (≤ 1.5 days)
  startup-script.sh + idpBuilder; helmfile.yaml.gotmpl; ArgoCD root-app
  files 12, 25, 26
  Verify: Backstage, ArgoCD, Gitea, Keycloak, Crossplane core all reachable
  ↳ ACCEPTANCE: AT-001 partial (deploy succeeds; surfaces reachable)

Stage 5 — Platform layer apps via ArgoCD (≤ 2 days)
  files 27–35, 71–73, 52–56, 125–130 (observability + Crossplane provider config + sandbox in-cluster)
  ↳ ACCEPTANCE: dashboards render; Crossplane reconciles a manual test bucket

Stage 6 — Bootstrap pod + dataset profiles (≤ 1 day)
  files 113–120, 68–70, 34
  Operator uploads 3 CSVs (DEFINE D-004); bootstrap Job generates profiles
  ↳ ACCEPTANCE: 3 profile rows in Supabase pgvector

Stage 7 — Agent prompts + kagent integration (≤ 1.5 days)
  files 57–64, 28, 32 (prompts ConfigMaps + kagent App)
  Hand-deploy a SINGLE test agent (NOT via Backstage yet) to verify A2A wiring works
  ↳ ACCEPTANCE: end-to-end A2A query works for one dataset

Stage 8 — Backstage template (≤ 2 days)
  files 74–91, 35
  ↳ ACCEPTANCE: AT-003 (form → working agent in ≤ 90s)

Stage 9 — Chat frontend (≤ 1.5 days)
  files 103–112, 42–44
  ↳ ACCEPTANCE: AT-004, AT-011 (streaming chat with chart)

Stage 10 — Kyverno policies (≤ 1 day)
  files 45–51, 30
  ↳ ACCEPTANCE: AT-006

Stage 11 — Budget controller (≤ 1 day)
  files 121–124, 65–67, 33
  ↳ ACCEPTANCE: AT-007

Stage 12 — CI + smoke + docs (≤ 1.5 days)
  files 131–140, 141–147
  ↳ ACCEPTANCE: AT-001 full, AT-013, AT-008, AT-010

TOTAL ≈ 15.5 working days for one developer at steady pace.
```

The single biggest risk to the schedule is **Stage 4** (IDP bootstrap): if `idpBuilder create` on the demo GCP VM has rough edges (proxy issues, image-pull rate limits, cert-manager rate limits), it can eat days. /build's task at start of Stage 4 should be a "spike" deploy on a throwaway VM before committing to this stage's full scope.

---

## 13. Security Considerations

(Concrete enforcement; see DEFINE Constraints + source plan §8.)

- **Per-agent isolation:** namespace + bucket + SA + SA key in agent's own namespace only; cross-namespace pod-to-pod denied by Kyverno-generated NetworkPolicy.
- **Per-execution credentials:** Sandbox NEVER retains SA keys between requests; `scoped_credentials` context manager guarantees deletion in `finally`.
- **Sandbox egress:** NetworkPolicy allows only DNS (UDP 53) + HTTPS to GCS endpoints (resolved IPs of `*.googleapis.com`, `storage.googleapis.com`). All other egress denied.
- **Pip blocked at runtime:** Sandbox image removes pip after build; whitelisted libs only.
- **Secrets:** SOPS-encrypted in git; age key out-of-band; in-cluster mounted as files (not env vars) where possible. Per-agent SA keys live ONLY in the agent's namespace.
- **Bootstrap SA scoping:** IAM Conditions limit roles to resources matching `agent-*` and `{project}-agent-*` patterns. Cannot touch project-wide IAM, billing, or other workloads in the project.
- **Image registries:** Kyverno allowlist = Gitea registry + pinned upstream registries (gcr.io/distroless/, ghcr.io/argoproj/, registry.k8s.io/, docker.io/library/python, quay.io/jetstack/, etc.).
- **Pod security:** all agent + sandbox pods run with `runAsNonRoot: true`, `readOnlyRootFilesystem: true`, no privilege escalation, no host namespaces.
- **Budget kill switch:** scales agent Deployments to 0 at 100% Langfuse-tracked cost; bounded financial blast radius.
- **Documented residual risks** (DEFINE Constraints + source plan §8.4): no Workload Identity (key-based auth on kind); no HA; sandbox isolation is defense-in-depth, not unbreakable; sslip.io reveals VM IP in hostnames.

---

## 14. Observability

| Aspect | Implementation |
|--------|----------------|
| **Logging** | Structured JSON via Python `logging` (sandbox, bootstrap, budget-controller); Next.js `pino` for chat-frontend; collected by Loki via Promtail DaemonSet |
| **Metrics** | Prometheus scrapes kube-state-metrics, NGINX, kagent controller, sandbox `/metrics` (custom counters: `sandbox_executions_total`, `sandbox_execution_duration_seconds`, `sandbox_oom_total`, `sandbox_timeout_total`); Mimir long-term storage |
| **Tracing** | OpenTelemetry: Python OTel auto-instrumentation in sandbox + bootstrap + budget-controller; browser OTel SDK in chat-frontend; kagent's built-in OTel for Agents. All to single OTel Collector → fan-out to Tempo + Langfuse (DD-6) |
| **LLM observability** | Langfuse Cloud — every Agent invocation, A2A hop, tool call traced; trace tagged with full agent identifier `agent-{name}-{xyz}` and `dataset:{dataset_id}`; per-agent cost rollup |
| **Dashboards (4 required + bonus)** | platform-health, agent-cost (Infinity-bridged), agent-performance, sandbox-execution. All in `platform/observability/dashboards/` provisioned via Helm ConfigMap |
| **Alerts** | Multi-window-multi-burn-rate SLO alerts (latency, error rate); per-agent budget alerts at 80% (warn) and 100% (page + auto-kill via budget-controller) |
| **Two-pane discipline** | Grafana = single pane for everything in cluster + aggregate cost; Langfuse = drill-down for per-query LLM specifics. NEVER duplicate LLM-specific data into Grafana beyond the aggregate-cost panel |

---

## 15. Open items deferred to /build

- **Memory spike (DD-8)** — first task; gates final value of `sandbox.memory_limit_bytes`.
- **Stage-4 idpBuilder spike** — verify VM-side bootstrap on a throwaway VM before locking startup-script.
- **Profile JSON schema final lock** — Pydantic shape in file 116 is a candidate; final-lock when the first end-to-end query runs against real profile data (Stage 7).
- **Final list of whitelisted Python libs in sandbox image** — start with source-plan §2.5 list (pandas, numpy, scipy, scikit-learn, matplotlib, seaborn, plotly); /build may add 1-2 (e.g., `python-dateutil`, `pyarrow`) when Online Retail II processing flushes them out.
- **Kagent CRD schema details** — depends on the kagent version pinned at /build start. Pattern 5 above is illustrative; final shape comes from the chosen release's CRD reference.

---

## Revision History

| Version | Date | Author | Changes |
|---------|------|--------|---------|
| 1.0 | 2026-05-04 | design-agent | Initial. Pre-flight inspection of operator-downloaded zips revealed Online Retail II is 95 MB (2.1× source-plan estimate); created DD-8 memory spike gate. Resolved DEFINE OQ-1..OQ-6 as DD-1..DD-6. Added DD-7 (unzipped CSVs at slugged paths), DD-9 (Helmfile bootstrap → ArgoCD steady state), DD-10 (Python budget-controller), DD-11 (shared prompts via ConfigMap). 147-file manifest; 13 specialist agents matched. 12-stage build phasing. |

---

## Next Step

**Ready for:** `/build .claude/sdd/features/DESIGN_whisperops.md`
