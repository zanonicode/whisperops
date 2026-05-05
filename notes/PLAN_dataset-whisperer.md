# DEFINE: Dataset Whisperer

> A self-service developer platform for shipping Data Analyst agents with multi-agent orchestration, observability, and governance — built to study and exercise modern AI Platform Engineering technologies.

---

## 0. One-line pitch

A cloud-native internal developer platform where any engineer ships a Data Analyst agent — answering questions about real datasets with executable code and interactive charts — by filling out a 4-field Backstage form, while the platform handles deployment, multi-agent orchestration, isolation, governance, observability, and cost control.

---

## 1. Why this project

### 1.1 The problem this explores

Operating LLM agents in production has become its own discipline in 2026. Costs are non-deterministic, prompts drift in quality without testing, agents have outsized blast radius if access controls fail, and observability requires its own toolchain (LLM-aware) on top of standard infrastructure observability. Most teams are figuring this out individually, repeating the same mistakes.

This project is an end-to-end study of what a coherent platform for those concerns looks like — combining a CNCF-aligned developer platform (CNOE/idpBuilder), a Kubernetes-native agent runtime (kagent), LLM observability tooling (Langfuse), declarative cloud resource provisioning (Crossplane), and an example agent that does genuinely useful work for non-technical users.

The goal is to learn each piece deeply by composing them into a working system, and to leave behind an architecture that can be referenced or extended.

### 1.2 What this is and isn't

This is a single-environment, cloud-deployed platform that provisions one type of agent (Data Analyst) over a curated set of three datasets, intended for hands-on study of:

- Internal developer platform construction (Backstage templates, GitOps with ArgoCD)
- Kubernetes-native AI agent runtime (kagent + A2A protocol)
- Multi-agent orchestration patterns
- LLM observability (Langfuse) integrated with infrastructure observability (LGTM)
- Policy as code for AI workloads (Kyverno)
- Per-agent isolation: dedicated namespace, GCS bucket, GCP service account
- Cost guardrails and budget enforcement
- Sandboxed code execution from LLM output
- Declarative cloud resource provisioning via Crossplane

This is not a production-grade product, not a competitor to commercial RAG platforms, and not an attempt to be feature-complete. It's deliberately scoped to exercise specific patterns end-to-end.

### 1.3 What success looks like

By the end of the build, the platform demonstrates:

1. A self-service developer experience that hides infrastructure complexity behind a simple form
2. Multi-agent A2A orchestration with genuine division of labor
3. Per-agent isolation: each agent runs in its own namespace with its own GCS bucket and GCP service account
4. Production-grade governance: policy-as-code, secrets management, cost guardrails
5. End-to-end observability across LLM traces, infrastructure metrics, and platform health
6. Real visible output: charts produced by sandboxed code execution, with traceable lineage from question to result
7. Declarative provisioning of cloud resources alongside Kubernetes resources via GitOps

---

## 2. The product: Dataset Whisperer

### 2.1 What it does

The platform produces one kind of agent: a Data Analyst Agent named "Dataset Whisperer". It answers natural-language questions about a curated set of datasets by:

1. Generating Python analysis code on demand
2. Executing that code in an isolated sandbox
3. Returning the result as a chart and a written explanation, with the code shown for transparency

A non-technical user can ask "what's the correlation between Spotify song danceability and popularity?" and receive back a scatter plot, a written explanation of the methodology used, and the Python snippet that produced it.

### 2.2 The Backstage template form

The developer creating the agent fills four fields:

| Field | Type | Purpose |
|---|---|---|
| Agent name | text | Identifier — base for namespace, bucket, subdomain, and resource naming |
| Description | text | Catalog metadata, shown to consumers |
| Dataset | dropdown | One of three curated datasets (see §2.3) |
| Primary LLM model | dropdown | Haiku (fast/cheap) or Sonnet (quality) |

That's it. No vector database choice, no embedding model selection, no chunking strategy, no source URL, no monthly budget. Every other decision is a platform default, deliberately abstracted away from the developer.

The agent name is validated to be DNS-compliant (lowercase, alphanumeric and hyphens, max 30 characters). The platform generates a 3-character random suffix that is appended to all resource names — this prevents naming conflicts on agent recreation and ensures GCS bucket names remain globally unique.

The model dropdown is exposed because choosing between cost and quality is a use-case decision, not a platform decision. The same platform serves casual analysis (Haiku is enough) and high-stakes analysis (Sonnet earns its cost).

### 2.3 The three curated datasets

The platform offers three datasets covering distinct analytical archetypes:

**Dataset 1: California Housing.** Classic regression dataset, ~20k rows, ~10 numeric features. Exercises correlation analysis, distribution plots, regression patterns.

**Dataset 2: Online Retail (UCI).** Transactional with timestamps, ~500k rows, ~45MB CSV. Exercises time-series decomposition, cohort analysis, RFM segmentation.

**Dataset 3: Spotify Tracks Dataset.** Mixed types (numeric audio features + categorical genres + textual titles), ~100k rows. Exercises exploratory data analysis, grouping by category, distribution comparisons.

The three datasets are downloaded once during platform bootstrap and stored in a shared GCS bucket (`{project-id}-datasets`) with read-only access granted to all agents' service accounts. This bucket is platform-managed, not per-agent.

### 2.4 The multi-agent runtime

Each Dataset Whisperer agent is internally a squad of three specialized agents communicating via the A2A protocol:

**Planner Agent (Haiku, fixed).** Receives the user's natural-language question and the dataset profile. Decides what kind of analysis is needed (EDA? correlation? time series?), what columns are relevant, and what output form the user expects. Outputs a structured plan for the Analyst.

**Analyst Agent (developer-selected model).** Receives the plan. Generates Python code that uses pandas, numpy, scipy, scikit-learn, matplotlib, or plotly to perform the analysis. Sends code to the Sandbox Service for execution. Receives results back, validates them, and synthesizes a factual summary with method justification.

**Writer Agent (developer-selected model).** Receives the Analyst's summary, the original question, the generated code, and the chart artifact. Formats the final response in didactic prose, displays the code transparently, and embeds the chart inline.

The Planner is always Haiku because routing decisions don't benefit from a larger model. Analyst and Writer use the model selected by the developer at agent creation time.

**Why this division justifies multi-agent.** Each agent does cognitively distinct work that benefits from a different prompt and observability scope. The Planner is a router; the Analyst is a code generator; the Writer is a communicator. Mixing these into a single agent forces compromises: the prompt grows long, the model must be top-tier for everything, and observability becomes coarse-grained. Three small specialized agents are simpler to evaluate, debug, and iterate than one large generalist agent.

**Why A2A specifically.** kagent supports the A2A (Agent-to-Agent) protocol natively. Each hop becomes a span in Langfuse traces. Latency, cost, and failure attribution are immediately visible per agent.

### 2.5 The Sandbox Service

Code generated by the Analyst executes in an isolated sandbox pod, not in the agent's own pod. This is non-negotiable: arbitrary code execution from an LLM near production cluster permissions is an incident waiting to happen.

The sandbox is a Python container with:

- A whitelisted set of packages (pandas, numpy, scipy, scikit-learn, matplotlib, seaborn, plotly)
- 60-second hard timeout per execution
- 3 GB memory cgroup limit
- Read-only filesystem except for `/tmp` for output artifacts
- NetworkPolicy via Kyverno: outbound only to GCS endpoints
- Per-execution credential injection (the agent's service account key, scoped to its specific buckets)

**Memory sizing rationale**: the largest dataset (Online Retail, ~45MB CSV) loads into pandas at ~150MB after dtype inference. Heavy operations (groupby + merge + pivot) can 2-3x the DataFrame in memory (~450MB). Library footprint at runtime is ~660MB (pandas 200MB + numpy 60MB + scipy 80MB + scikit-learn 150MB + matplotlib 80MB + plotly 50MB + Python interpreter 40MB). Worst-case operation peaks at ~1.5GB. The 3GB limit covers this with comfortable headroom for clustering or feature engineering, while staying well within the VM's available memory.

The Sandbox is implemented as a pool of pre-warmed pods (1-2 pods) accessible by all agents. The pool runs in a dedicated `sandbox` namespace. Each execution runs in a fresh subprocess inside a pool pod, isolated from concurrent requests by process boundaries and per-execution credentials.

When an agent submits code to the Sandbox, it includes:
- The code itself
- A reference to which dataset to load (signed URL provided by the agent)
- The agent's GCS service account key for writing artifacts to the agent's own bucket

Charts are saved as PNG (matplotlib) or HTML (plotly interactive) files in `/tmp` and uploaded to the agent's per-agent GCS bucket with a short-lived signed URL. The URL is returned to the Writer agent, which embeds it in the response.

### 2.6 Output: chat with embedded charts

The user-facing surface is a minimal Next.js chat application served per agent. It:

- Renders markdown responses
- Displays inline images (chart PNGs from signed URLs)
- Embeds interactive Plotly charts via iframe when applicable
- Shows code blocks with syntax highlighting
- Streams responses token-by-token as the Writer produces them

Each agent has its own chat frontend instance, deployed in the agent's namespace and exposed at its own subdomain. Backstage is where developers create agents; the chat is where consumers use them. Separating these surfaces matches how mature IDPs actually work.

---

## 3. Architecture

### 3.1 The high-level picture

The system has three layers:

**Layer 1: Cloud infrastructure.** A single GCE VM running a kind cluster, with GCS for storage, static external IP, and DNS via sslip.io. Provisioned by Terraform.

**Layer 2: Internal Developer Platform.** kind cluster bootstrapped by idpBuilder, containing Backstage (developer portal), ArgoCD (GitOps reconciler), Gitea (in-cluster git), Keycloak (SSO), Crossplane (active — provisions per-agent cloud resources), External Secrets Operator (secrets sync), Kyverno (policies), NGINX Ingress, cert-manager.

**Layer 3: Agent Platform.** kagent controller managing Agent CRDs, the LGTM observability stack, the Dataset Whisperer template generator, the Sandbox service pool, and per-agent chat frontends.

**SaaS dependencies (out of cluster):**

- **Anthropic API** — LLM provider for all three agents
- **OpenAI API** — used only for `text-embedding-3-small` (dataset profile embeddings, very low cost)
- **Supabase** — Postgres with pgvector for storing dataset profiles and analysis history
- **Langfuse Cloud** — LLM trace storage, evaluation, cost tracking

### 3.2 Why each component

**GCP / Compute Engine.** $300 free credits cover the entire project. Spot VMs reduce cost by 60-80% during development.

**VM running kind, not GKE.** GKE would mean adapting CNOE reference implementation patterns from EKS (the only documented one) to GCP — multi-week plumbing that doesn't appear in the running platform. A VM running kind keeps the architecture simple. In a real production deployment, the same Helm charts and ArgoCD applications would run on GKE; the platform layer is portable.

**idpBuilder (CNOE).** Provides a vetted, opinionated bootstrap of an internal developer platform with a single binary. Backstage, ArgoCD, Gitea, Keycloak, Crossplane all configured to work together out of the box.

**Backstage.** The de facto standard developer portal. Templates produce a Pull Request to a Git repo — perfect fit for the GitOps flow.

**Gitea (in-cluster).** Templates produce PRs against Gitea, ArgoCD watches Gitea repos. Self-contained: no external GitHub dependency, no GitHub App credentials, no rate limits.

**ArgoCD.** GitOps reconciler. App-of-apps pattern syncs everything from Gitea declaratively.

**kagent.** Kubernetes-native agent runtime. Agents are CRDs, the controller reconciles them like any other workload. Native A2A protocol support. OTel-instrumented.

**Crossplane (active in MVP).** Provisions per-agent cloud resources declaratively: GCS buckets, GCP service accounts, service account keys. The Backstage template generates Crossplane CRDs alongside Kubernetes resources, ArgoCD applies them, Crossplane controllers reconcile against GCP. This makes cloud resources first-class GitOps citizens — committed to git, versioned, deletable as a unit when the agent is removed.

**Supabase pgvector, not a dedicated vector DB.** The platform stores small structured artifacts (dataset profiles, analysis history) plus their embeddings. Volume is modest. Standalone vector database would be over-provisioning. pgvector represents the more common production pattern: most enterprises extend Postgres rather than adopt a new database.

**Anthropic for LLMs.** Strong cost-per-quality at both Haiku and Sonnet tiers. Clean function calling for tool use. Single provider in MVP simplifies operational thinking; multi-provider routing is deferred.

**OpenAI only for embeddings.** `text-embedding-3-small` is the most cost-effective embedding model in 2026. Multi-vendor in this small role demonstrates pragmatism over loyalty.

**Langfuse Cloud, not self-hosted.** Self-hosting Langfuse means running ClickHouse + Postgres + worker + web — 2-3GB RAM and significant operational overhead. Cloud free tier covers the project's volume comfortably.

**LGTM in cluster.** Loki for logs, Grafana for visualization, Tempo for traces, Prometheus for metrics. Single pane of glass for everything that happens inside the cluster. Langfuse covers LLM-specific observability; LGTM covers infrastructure.

**Kyverno for policy.** Declarative policy as YAML, integrates cleanly with ArgoCD app-of-apps, no Rego learning curve like OPA Gatekeeper.

**SOPS + age for secrets.** Secrets committed encrypted to git. Single age key decrypts everything. Onboarding is two commands: place key, run make.

**Terraform.** Industry standard for IaC. State stored in a GCS backend bucket. Modules for VM, networking, DNS, storage.

**Helmfile for app deployment.** Orchestrates multiple Helm releases with `needs:` ordering.

**Python (FastAPI) for the Sandbox service.** Sandbox is a thin HTTP service that accepts code, executes it in a subprocess, returns artifacts. FastAPI is the right tool: simple, async-native, OTel-instrumented out of the box.

**TypeScript (Next.js) for the chat frontend.** Server-Sent Events for streaming. Tailwind for styling. Thin shell, not where the project's value lives.

### 3.3 Per-agent isolation model

Each agent created via the Backstage template gets its own dedicated set of resources. The naming convention uses the agent name plus a 3-character random suffix (lowercase alphanumeric):

```
Agent name input:        spotify-explorer
Random suffix:           a7k

Generated resources:

Kubernetes namespace:    agent-spotify-explorer-a7k
GCS bucket:              {project-id}-agent-spotify-explorer-a7k
GCP service account:     agent-spotify-explorer-a7k@{project-id}.iam.gserviceaccount.com
Subdomain:               agent-spotify-explorer-a7k.{IP}.sslip.io
Langfuse tag:            agent-spotify-explorer-a7k
```

The per-agent GCS bucket stores chart artifacts produced by that agent. It is also forward-compatible with future per-agent dataset uploads (when the dataset field is opened to free input in a later iteration, the bucket already exists for hosting agent-specific data).

The shared dataset bucket (`{project-id}-datasets`) hosts the three curated datasets. All agent service accounts have read-only access to this bucket. Agents do not duplicate datasets into their own buckets.

The GCP service account is created per-agent so that:

- IAM permissions are scoped: each SA has `roles/storage.objectViewer` on the shared dataset bucket and `roles/storage.objectAdmin` on its own per-agent bucket
- Audit logs trace cloud actions to specific agents
- Service accounts can be deleted as a unit when the agent is removed

The service account key is generated by Crossplane (`ServiceAccountKey` resource), stored in a Kubernetes Secret in the agent's namespace, and mounted into the Sandbox pod at execution time as a per-execution credential. Every Sandbox invocation runs with the requesting agent's specific credential — pool pods do not retain or share credentials between invocations.

**On Workload Identity**: Workload Identity (the production pattern for K8s-to-GCP authentication) requires GKE's metadata service. Since the platform runs kind on a GCE VM, Workload Identity is not available, and key-based authentication is used instead. In a GKE production deployment, the Crossplane definitions would swap `ServiceAccountKey` for an `IAMPolicyMember` Workload Identity binding — this is a small change documented in the project's notes.

### 3.4 Network and DNS

The VM has a static external IP. DNS resolution happens via sslip.io: an IP `34.121.45.67` becomes accessible at `*.34-121-45-67.sslip.io`. NGINX Ingress in the cluster splits hosts:

- `backstage.{IP}.sslip.io` → Backstage
- `argocd.{IP}.sslip.io` → ArgoCD UI
- `gitea.{IP}.sslip.io` → Gitea UI
- `grafana.{IP}.sslip.io` → Grafana
- `agent-{name}-{xyz}.{IP}.sslip.io` → chat frontend for that specific agent

The Backstage template generates a Kubernetes `Ingress` resource with the agent-specific hostname. NGINX Ingress picks it up automatically — no cloud LB is created per agent, no DNS record is configured per agent. sslip.io's wildcard DNS resolution and cert-manager's automatic certificate issuance handle the rest.

cert-manager issues TLS certificates from Let's Encrypt for all hostnames automatically using HTTP-01 challenge.

### 3.5 Data flow: provisioning a new agent

When a developer fills out the Backstage form and clicks Submit:

1. Backstage's scaffolder generates a 3-character random suffix and a directory of YAML manifests from the template, including:
   - K8s `Namespace` (`agent-{name}-{xyz}`)
   - Crossplane `Bucket` (provider-gcp) for the per-agent bucket
   - Crossplane `ServiceAccount` (provider-gcp) for the per-agent GCP SA
   - Crossplane `IAMMember` granting the SA `objectViewer` on the shared dataset bucket
   - Crossplane `IAMMember` granting the SA `objectAdmin` on the per-agent bucket
   - Crossplane `ServiceAccountKey` that materializes a Kubernetes Secret in the agent namespace
   - 3x kagent `Agent` CRDs (Planner, Analyst, Writer)
   - kagent `ToolServer` CRD pointing at the shared Sandbox service
   - K8s `Service` and `Deployment` for the per-agent chat frontend
   - K8s `Ingress` with agent-specific hostname
   - Kyverno `Policy` constraining the agent namespace
   - ArgoCD `Application` watching this directory
2. Files are committed as a PR to a Gitea repository (`agents/{agent-name}-{xyz}/`)
3. CI pipeline runs smoke evals on the PR: validates manifests against schemas, verifies naming conventions, checks dataset reference, runs a mock execution against a fixed test question
4. On merge, ArgoCD detects the new path and syncs the manifests in dependency order
5. Crossplane provisions the GCP resources (bucket, service account, IAM bindings, key) — typically 30-60 seconds
6. ArgoCD applies the K8s resources; External Secrets Operator picks up the SA key Secret
7. kagent's controller reconciles the new Agent CRDs, creates Deployments and Services
8. Kyverno validates the new pods comply with policy
9. The agent appears in Backstage's catalog with a link to its chat URL
10. Total time from PR merge to working agent: ~60-90 seconds

### 3.6 Data flow: a query at runtime

When a user types a question in the chat frontend:

1. Chat frontend POSTs to the Planner agent's HTTP endpoint (within the agent's namespace)
2. Planner reads the user question + dataset profile (cached at provisioning time) and generates a structured plan
3. Planner makes an A2A call to Analyst with the plan
4. Analyst retrieves the dataset signed URL, then generates Python code that performs the requested analysis
5. Analyst calls the Sandbox service (in the `sandbox` namespace) over HTTP with the code, dataset reference, and agent's SA key
6. Sandbox executes the code in a subprocess with the agent's credentials, reads the dataset from the shared bucket, performs the analysis, saves a chart to `/tmp`, then uploads it to the agent's per-agent bucket
7. Sandbox returns the signed URL of the chart, plus stdout, plus any error
8. Analyst synthesizes a factual summary
9. Analyst makes an A2A call to Writer with the summary, original question, generated code, and chart URL
10. Writer formats the final didactic response
11. Response streams back to the chat frontend token-by-token
12. Every step emits OTel spans to Langfuse — the full trace is visible end-to-end, tagged with the agent's full name (`agent-{name}-{xyz}`)

Cost per query (typical): ~$0.04 with Sonnet, ~$0.01 with Haiku. Latency p50: ~10-15 seconds end-to-end.

---

## 4. Repository structure

```
dataset-whisperer/
├── README.md                          # Project front door, quickstart, demo video link
├── Makefile                           # deploy, destroy, smoke-test
├── .sops.yaml                         # SOPS rules: which files to encrypt
├── .gitignore                         # Excludes age key, terraform local state cache
│
├── docs/
│   ├── DEPLOYMENT.md                  # Step-by-step deploy guide
│   ├── ARCHITECTURE.md                # Component diagrams, data flows
│   ├── OBSERVABILITY.md               # Dashboard walkthrough, trace examples
│   ├── SECURITY.md                    # Threat model, controls, residual risks
│   └── runbooks/
│       ├── platform-bootstrap.md
│       ├── agent-creation.md
│       └── incident-response.md
│
├── terraform/                         # Cloud infrastructure (VM, networking, shared buckets)
│   ├── main.tf
│   ├── variables.tf
│   ├── outputs.tf
│   ├── backend.tf                     # GCS state backend
│   ├── modules/
│   │   ├── network/                   # VPC, firewall, static IP
│   │   ├── compute/                   # GCE instance, startup script
│   │   ├── storage/                   # Shared GCS buckets (datasets, terraform state)
│   │   └── iam/                       # Bootstrap SA, project-level bindings
│   └── envs/
│       └── demo/
│           └── terraform.tfvars
│
├── platform/                          # Everything that runs inside the cluster
│   ├── helmfile.yaml.gotmpl           # Orchestrates all releases
│   ├── argocd/
│   │   ├── bootstrap/
│   │   │   └── root-app.yaml          # App-of-apps entry point
│   │   └── applications/
│   │       ├── observability.yaml     # LGTM stack
│   │       ├── kagent.yaml            # kagent controller + CRDs
│   │       ├── crossplane-providers.yaml  # provider-gcp configuration
│   │       ├── kyverno.yaml           # Policy engine + policies
│   │       ├── sandbox.yaml           # Sandbox service deployment
│   │       └── agents.yaml            # Watches /agents in Gitea
│   │
│   ├── helm/                          # Project-local Helm charts
│   │   ├── sandbox/
│   │   ├── chat-frontend/             # Templated, deployed per agent
│   │   ├── kyverno-policies/
│   │   └── observability-extras/
│   │
│   ├── crossplane/                    # Crossplane provider config and base CompositeResources
│   │   ├── provider-gcp.yaml
│   │   ├── provider-config.yaml
│   │   └── compositions/              # Reusable Crossplane Compositions for agent resources
│   │
│   └── observability/
│       ├── dashboards/
│       │   ├── platform-health.json
│       │   ├── agent-cost.json
│       │   ├── agent-performance.json
│       │   └── sandbox-execution.json
│       └── alerts/
│           ├── platform-slos.yaml
│           └── budget-burn.yaml
│
├── backstage-templates/
│   └── dataset-whisperer/
│       ├── template.yaml              # Form definition, scaffolder steps (incl. random suffix gen)
│       ├── skeleton/                  # Templated files
│       │   ├── namespace.yaml.njk
│       │   ├── bucket.yaml.njk        # Crossplane Bucket
│       │   ├── service-account.yaml.njk  # Crossplane ServiceAccount + Key
│       │   ├── iam-bindings.yaml.njk  # Crossplane IAMMember resources
│       │   ├── agent-planner.yaml.njk
│       │   ├── agent-analyst.yaml.njk
│       │   ├── agent-writer.yaml.njk
│       │   ├── toolserver-sandbox.yaml.njk
│       │   ├── kyverno-policy.yaml.njk
│       │   ├── chat-frontend.yaml.njk
│       │   ├── ingress.yaml.njk
│       │   └── argocd-app.yaml.njk
│       └── README.md
│
├── src/
│   ├── sandbox/                       # Python — FastAPI service
│   │   ├── pyproject.toml
│   │   ├── Dockerfile
│   │   ├── app/
│   │   │   ├── main.py
│   │   │   ├── execution.py           # Subprocess management, timeouts
│   │   │   ├── credentials.py         # Per-execution SA key handling
│   │   │   ├── artifact_upload.py     # GCS chart upload
│   │   │   ├── observability.py
│   │   │   └── schemas.py
│   │   └── tests/
│   │
│   ├── chat-frontend/                 # TypeScript — Next.js app
│   │   ├── package.json
│   │   ├── Dockerfile
│   │   ├── app/
│   │   │   ├── page.tsx
│   │   │   ├── api/
│   │   │   │   └── chat/route.ts      # SSE proxy to Planner
│   │   │   └── components/
│   │   │       ├── Message.tsx
│   │   │       ├── ChartEmbed.tsx
│   │   │       └── CodeBlock.tsx
│   │   └── lib/
│   │       ├── sse.ts
│   │       └── observability.ts
│   │
│   └── platform-bootstrap/            # Python — runs once during deploy
│       ├── pyproject.toml
│       ├── Dockerfile
│       ├── bootstrap.py               # Downloads datasets, generates profiles, populates pgvector
│       └── profiles/                  # Pre-computed dataset profiles (committed)
│           ├── california-housing.json
│           ├── online-retail.json
│           └── spotify-tracks.json
│
├── secrets/                           # SOPS-encrypted
│   ├── anthropic.enc.yaml
│   ├── openai.enc.yaml
│   ├── supabase.enc.yaml
│   ├── langfuse.enc.yaml
│   └── crossplane-gcp-creds.enc.yaml  # Bootstrap credentials for Crossplane provider
│
├── tests/
│   ├── smoke/
│   │   ├── platform-up.sh
│   │   ├── agent-creation.sh
│   │   └── query-roundtrip.sh
│   └── eval/
│       └── agent-template-validation/
│           ├── fixtures/
│           └── run-evals.py
│
└── .github/workflows/
    ├── ci.yml
    ├── agent-eval.yml
    └── release.yml
```

---

## 5. Deployment: clone to first query

### 5.1 Prerequisites

- A GCP account with billing enabled (the $300 free credits cover the project)
- `gcloud` CLI authenticated: `gcloud auth application-default login`
- `terraform` >= 1.6
- `kubectl` >= 1.28
- `make`
- An age private key for SOPS decryption (generated once with `age-keygen`)
- API keys for Anthropic, OpenAI, Supabase project, Langfuse project (created once)

### 5.2 Step-by-step

```bash
# 1. Clone
git clone <repo-url>
cd dataset-whisperer

# 2. Place the age key for SOPS decryption
mkdir -p ~/.config/sops/age
cp /path/to/key.txt ~/.config/sops/age/keys.txt

# 3. Set GCP project
export TF_VAR_project_id=your-gcp-project
export TF_VAR_region=us-central1

# 4. One command provisions everything
make deploy
```

This runs:

1. `terraform init && terraform apply`
   - Creates VPC, firewall, static IP
   - Creates GCE VM with startup script
   - Creates shared GCS buckets (datasets, terraform state)
   - Creates a bootstrap SA with project-level Crossplane permissions
   - VM startup script installs Docker, downloads idpbuilder, runs `idpbuilder create`
2. Waits for cluster ready (~5 min)
3. SOPS decrypts secrets, applies via kubectl
4. Helmfile applies platform components (LGTM, kagent, Crossplane providers, Kyverno, sandbox)
5. ArgoCD bootstrap creates app-of-apps
6. Bootstrap pod runs `platform-bootstrap` container — downloads 3 datasets to GCS, generates profiles, populates Supabase pgvector
7. Smoke tests verify everything is healthy
8. Make outputs URLs of all surfaces

Total time on a fresh GCP project: ~15-20 minutes.

### 5.3 Using the platform

After `make deploy` completes:

```
Backstage:        https://backstage.{IP}.sslip.io
ArgoCD:           https://argocd.{IP}.sslip.io
Grafana:          https://grafana.{IP}.sslip.io
Chat (per agent): https://agent-{name}-{xyz}.{IP}.sslip.io
```

To create an agent:

1. Navigate to Backstage
2. Click "Create"
3. Select template "Dataset Whisperer"
4. Fill the form (4 fields)
5. Submit
6. Wait ~60-90 seconds for Crossplane + ArgoCD to provision everything
7. Click the link in Backstage catalog → opens chat
8. Ask: "What's the strongest predictor of price in this dataset?"
9. Receive: written explanation + Python code + chart, in ~10-15 seconds

### 5.4 Tearing down

```bash
make destroy
```

Tears down the entire GCE infrastructure including all per-agent resources (Crossplane reconciles deletion of buckets and service accounts when their CRDs are removed). Idempotent.

SaaS resources (Supabase project, Langfuse project) are persistent — they remain free-tier and don't accumulate cost.

---

## 6. In-cluster infrastructure deep dive

### 6.1 The kind cluster

A single-node kind cluster runs inside the GCE VM. Configuration:

- Single node (control plane + workload), to maximize utilization of the VM's resources
- Custom kind config exposes ports 80 and 443 to the host
- Container runtime: containerd
- CNI: kindnet

The VM's startup script installs Docker, downloads the idpbuilder binary, and runs idpbuilder. After this, the cluster is reachable from outside the VM via the host hostnames.

### 6.2 idpBuilder core packages

idpBuilder bootstraps:

- **NGINX Ingress Controller** — the cluster's edge
- **cert-manager** — TLS via Let's Encrypt (HTTP-01)
- **ArgoCD** — GitOps reconciler
- **Gitea** — in-cluster Git server, embedded OCI registry
- **Keycloak** — SSO (used by Backstage, ArgoCD, Grafana via OIDC)
- **Crossplane** — Kubernetes-native cloud resource provisioning (active in this project)
- **External Secrets Operator** — sync secrets from external stores into the cluster
- **Backstage** — developer portal, with the Dataset Whisperer template registered

### 6.3 Platform-specific additions

On top of idpBuilder's core, the project adds:

- **Crossplane provider-gcp** — configured with bootstrap SA credentials to provision GCS buckets and IAM resources
- **kagent** — agent runtime CRDs + controller (Helm chart from kagent.dev)
- **LGTM stack** — Loki + Grafana + Tempo + Prometheus
- **OpenTelemetry Collector** — single deployment that receives OTLP from agents, sandbox, chat frontends, exports to Tempo/Prometheus/Loki
- **Kyverno** — policy engine + the project's policy bundle
- **Sandbox service** — pool of 1-2 pods running the FastAPI sandbox in the `sandbox` namespace
- **Per-agent stacks** — Deployment + Service + Ingress + 3 Agent CRDs per Dataset Whisperer agent, in isolated namespaces

### 6.4 Resource allocation

| Component | Memory | CPU |
|---|---|---|
| kind base + containerd | 1 GB | 0.3 |
| NGINX Ingress + cert-manager | 200 MB | 0.1 |
| ArgoCD | 600 MB | 0.2 |
| Gitea | 300 MB | 0.1 |
| Keycloak | 800 MB | 0.2 |
| Backstage | 800 MB | 0.2 |
| Crossplane core + provider-gcp | 600 MB | 0.2 |
| External Secrets Operator | 150 MB | 0.05 |
| LGTM stack | 2 GB | 0.5 |
| OTel Collector | 200 MB | 0.1 |
| kagent controller | 200 MB | 0.1 |
| Kyverno | 500 MB | 0.2 |
| Sandbox pool (2 pods, idle) | 1 GB | 0.2 |
| Sandbox burst during execution | +3 GB | +1.0 |
| Per-agent stack (3 agent pods + chat frontend) | ~800 MB | ~0.2 |
| **Total at idle (1 agent)** | **~9.5 GB** | **~2.65 vCPU** |
| **Total during query** | **~12.5 GB** | **~3.65 vCPU** |

This fits comfortably in a `e2-standard-8` VM (32 GB / 8 vCPU). Sized 2-3x above peak for parallel queries and multiple agents.

---

## 7. SaaS dependencies

### 7.1 Anthropic API

Used for all three agents. Models: Planner uses Haiku; Analyst and Writer use the model selected by the developer at agent creation time.

Cost estimate per query: ~$0.04 with Sonnet, ~$0.01 with Haiku. For a development/demo session of 50 queries: $0.50–$2.

Authentication: API key, stored encrypted in `secrets/anthropic.enc.yaml`, synced into the cluster via External Secrets Operator into agent namespaces.

### 7.2 OpenAI API

Used only for text embedding (`text-embedding-3-small`). Not used for any LLM completion in the MVP.

Cost estimate: <$0.50 total. Embeddings are computed once during platform bootstrap.

### 7.3 Supabase

Postgres database with pgvector extension.

Schema:

- `dataset_profiles` table — one row per curated dataset, with structured metadata and a vector embedding of the profile description
- `analysis_history` table — append-only log of every query/response pair, with embedding of the question

Free tier coverage: 500 MB database storage, 8 GB pgvector storage, unlimited API requests for low volume.

Authentication: service role key (write, used by bootstrap pod) and anon key (read, used by agents).

### 7.4 Langfuse Cloud

LLM observability — every agent invocation, A2A hop, and tool call is traced.

Free tier coverage: 50,000 observations per month. Each query produces ~10-15 observations.

Integration: agents are configured with Langfuse OTel exporter. Traces are visible in Langfuse dashboard with full prompt/completion text, latency per span, and per-call cost.

Cost rollup: Langfuse aggregates costs by trace and by tag. Each agent's full identifier (`agent-{name}-{xyz}`) becomes a tag on every trace, enabling per-agent cost dashboards.

---

## 8. Security

### 8.1 Threat model summary

**Assets**:
- LLM API keys (Anthropic, OpenAI)
- Supabase service role key
- Langfuse credentials
- Crossplane bootstrap SA credentials (powerful — can create cloud resources)
- Per-agent service account keys
- The cluster itself
- The sandbox (potential RCE target if isolation fails)

**Adversaries**:
- External attacker scanning public IPs
- Malicious user creating an agent with a hostile prompt
- Compromised dependency (supply chain)
- The LLM itself producing harmful code (prompt injection, jailbreak)

**Out of scope for MVP**: insider threat, compromised CI, advanced persistent threats.

### 8.2 Controls by layer

**Cloud layer (Terraform)**:

- VM has external IP but firewall allows only ports 22 (SSH from a single IP CIDR), 80 (HTTP for Let's Encrypt), and 443 (HTTPS)
- SSH uses key-based auth only
- VM service account has minimal IAM (read on shared dataset bucket, ability to manage Crossplane bootstrap resources only)
- Crossplane bootstrap SA has scoped permissions: only create/manage buckets and SAs under a specific naming prefix; cannot touch project-wide IAM
- GCS buckets are private by default; signed URLs grant time-limited read access
- Terraform state in a GCS bucket with bucket-level encryption and versioning

**Cluster layer**:

- Keycloak provides SSO for Backstage, ArgoCD, Grafana
- Default deny network policies via Kyverno (only explicitly allowed flows pass)
- All ingress is via NGINX Ingress with cert-manager TLS — no plaintext
- ArgoCD's repo credentials (Gitea) live in a Sealed Secret managed by idpBuilder
- External Secrets Operator only syncs into namespaces with explicit `ExternalSecret` resources

**Per-agent isolation**:

- Each agent runs in a dedicated namespace; pods cannot reach pods in other agent namespaces (NetworkPolicy default-deny)
- Each agent has its own GCP service account with minimal permissions (read shared datasets, write own bucket)
- The SA key is stored only in the agent's namespace; it cannot be read by other namespaces
- Sandbox executions use the requesting agent's specific credentials, scoped to that agent's bucket
- A malicious agent cannot read or write artifacts from another agent's bucket

**Agent layer (Kyverno policies)**:

- All Agent pods must declare `requests` and `limits`
- Agent pods run with `runAsNonRoot: true`, no privilege escalation, read-only root filesystem
- Agent pods can only pull images from the in-cluster Gitea registry or a pinned set of upstream registries
- Agent pods may only egress to: anthropic.com, openai.com, supabase.co, langfuse.com, and the sandbox service inside the cluster
- Agent pods cannot mount the host filesystem or access the kubelet

**Sandbox layer**:

- Sandbox pod runs in the `sandbox` namespace with a default-deny network policy
- The pool pod itself has no service account token mounted
- Per-execution credentials are passed via environment variable, scoped to the requesting agent's resources
- The Python subprocess is started with a 60-second hard timeout, 3 GB memory cgroup, restricted to `/tmp` for filesystem writes
- Whitelisted Python packages installed in the base image; `pip install` at runtime is blocked
- Network egress restricted to GCS endpoints only

**LLM layer**:

- Per-agent budget tracked via Langfuse tags; alerts fire when 80% is reached and the agent's deployment is scaled to zero at 100% (kill switch)
- All agent prompts are committed to git and reviewed via PR
- Agent system prompts include instructions to refuse off-task requests

**Secrets**:

- All secrets are SOPS-encrypted in git
- The age decryption key is never committed; distributed out-of-band
- In-cluster, secrets are mounted as files (not env vars) wherever possible
- Per-agent SA keys are generated by Crossplane and rotated by recreating the resource

### 8.3 Kyverno policies (concrete list for MVP)

| Policy | Enforcement | Purpose |
|---|---|---|
| `require-resource-limits` | enforce | All pods in agent namespaces must declare CPU/memory limits |
| `disallow-privileged` | enforce | No `privileged: true`, no host namespaces |
| `restrict-image-registries` | enforce | Only Gitea registry + pinned upstream registries |
| `agent-egress-allowlist` | enforce | NetworkPolicy template auto-applied to every agent namespace |
| `sandbox-isolation` | enforce | Sandbox namespace has stricter NetworkPolicy than agent namespaces |
| `require-budget-annotation` | audit | Every Agent CRD must declare budget metadata |
| `validate-image-signatures` | audit | Future: cosign verification |

### 8.4 Residual risks

- **Single-node cluster**: no HA. Pod restart causes brief downtime.
- **No image signing**: Kyverno could enforce cosign, but the toolchain to sign all images during the build is deferred.
- **Sandbox is not unbreakable**: if a malicious LLM generates code that escapes Python (e.g., a known CVE in pandas), the sandbox is the last line of defense. Network policy prevents data exfiltration to non-GCS endpoints, but compute exhaustion is possible. Mitigation: aggressive timeouts and resource limits.
- **Key-based GCP auth instead of Workload Identity**: kind doesn't support GKE's metadata service; SA keys are used. In a GKE deployment, this would be Workload Identity.
- **DNS via sslip.io**: the IP of the VM is publicly visible in the hostname. Not a real vulnerability, but documented.

---

## 9. Observability

### 9.1 The two-pane strategy

The platform has two distinct observability surfaces, each authoritative for its domain:

**Langfuse Cloud**: authoritative for LLM operations. Per-agent cost, per-call latency, prompt/completion text, A2A trace topology, eval scores. This is where you debug "why did Agent X give a bad answer".

**Grafana (in-cluster)**: authoritative for everything else. Cluster health, controller reconciliation lag, ingress traffic, sandbox throughput, Pod resource usage, ArgoCD sync status, Crossplane reconciliation status. This is where you debug "why is Agent X slow" or "why is the cluster unhealthy".

These two surfaces are connected: Grafana has an Infinity datasource panel that pulls aggregate cost data from Langfuse's REST API into a "platform-wide cost" dashboard. Grafana remains the single pane of glass for high-level health; Langfuse is the drill-down for LLM specifics.

### 9.2 Dashboards (concrete list for MVP)

**Platform Health** (`platform-health.json`):
- Cluster node CPU/memory
- ArgoCD sync status per app
- Crossplane reconciliation status per resource
- kagent controller reconciliation rate
- NGINX Ingress request rate, p50/p95/p99 latency
- cert-manager certificate expiry

**Agent Cost** (`agent-cost.json`):
- Total LLM cost per day (from Langfuse via Infinity)
- Top-10 most expensive agents
- Cost per query distribution
- Budget burn rate per agent

**Agent Performance** (`agent-performance.json`):
- p50/p95/p99 query latency per agent
- A2A hop breakdown (planner/analyst/writer time fractions)
- Sandbox execution time distribution
- Error rate per agent, broken down by error type

**Sandbox Execution** (`sandbox-execution.json`):
- Concurrent executions, queue depth
- Timeout rate, OOM rate
- Top-10 packages imported
- Chart artifact upload latency

### 9.3 Tracing

OpenTelemetry instrumentation flows:

- `chat-frontend` (browser OTel SDK) → OTel Collector → Tempo
- Each agent pod (kagent's built-in OTel) → OTel Collector → Tempo + Langfuse
- `sandbox` (Python OTel auto-instrumentation) → OTel Collector → Tempo

A single trace from a user query has spans across: browser → ingress → planner → analyst → sandbox → writer → ingress → browser. Tempo's TraceQL query interface allows filtering by agent, by user, by trace duration.

### 9.4 Smoke evals (CI-driven)

Every PR that adds or modifies an Agent CRD triggers a smoke eval:

1. PR creates/modifies files under `agents/{agent-name}-{xyz}/`
2. CI workflow detects the change
3. Workflow spins up a temporary kind cluster, applies the agent (mocking Crossplane resources)
4. Workflow runs a fixed test question against the agent
5. Workflow asserts: response received, no errors, response includes expected schema (text + chart URL), latency under 30 seconds
6. If pass: PR can merge. If fail: PR blocked.

This is intentionally a structural eval, not a quality eval. The platform validates that agents work, not that their answers are good.

---

## 10. Out of scope (and why)

Documenting what the project deliberately does not do is as important as documenting what it does. These are decisions, not gaps.

**Local development mode.** The project is cloud-only. No `make dev-up` for kind on a laptop.

**Multi-cloud or cloud-portable abstractions.** The Terraform modules and Crossplane providers are GCP-specific. Porting to AWS/Azure is documented as future work but not implemented.

**LiteLLM gateway.** Considered for cost tracking and multi-provider routing, deferred. Justification: Langfuse already provides cost tracking at the trace level; multi-provider routing is a feature without a use case in the MVP.

**Self-hosted Langfuse, Vector DB, or other SaaS components.** Considered, rejected. Self-hosting these in cluster adds significant operational complexity for no functional gain.

**Quality evals (LLM-as-judge) at platform level.** The platform runs structural smoke evals on agent PRs. Quality evals require a labeled dataset of "good answers" per agent, which doesn't generalize across agents.

**External notification integrations (Slack, Discord, email).** Considered, removed. The Dataset Whisperer is a synchronous request/response system — no async events demand notification.

**Knowledge bases curated outside the dataset itself.** Considered, rejected. LLMs already know data analysis patterns, Python idioms, statistics fundamentals. A curated KB would reproduce that knowledge with maintenance overhead.

**Open-ended dataset URLs.** Considered, deferred. Letting a developer paste any URL invites cost incidents (scraping Wikipedia accidentally) and security risks. Three curated datasets cover the project's needs. Future iteration: dataset upload by developer, where the per-agent bucket already exists (provisioned by Crossplane today) ready to receive uploaded data.

**Workload Identity.** kind doesn't support GKE's metadata service. Per-agent SA keys are used instead.

**Image signing (cosign).** Kyverno policies can enforce signed images. The signing toolchain is deferred.

**HA / multi-node cluster.** Single-node kind in a single VM. Acceptable for the project's scope; not for production.

---

## 11. Possible future improvements

These are not commitments — they're direction-setting for what a v0.4, v0.5 might look like.

**v0.4 — Production hardening**:
- LiteLLM gateway with multi-provider fallback
- Image signing via cosign + Kyverno verification
- Migration to GKE proper, with Workload Identity replacing SA keys
- Quality eval templates, opt-in per agent

**v0.5 — Open dataset input**:
- The dataset field becomes a free-input URL or upload
- Per-agent bucket (already provisioned by Crossplane) hosts the developer-supplied dataset
- Cost guardrails on indexing: validate dataset size before processing, fail closed if estimated embedding cost exceeds threshold
- Pattern is already in place; v0.5 is mostly Backstage template changes plus dataset validation logic

**v0.6 — Multi-tenancy**:
- Multiple "organizations" with isolated namespaces, quota, dataset visibility
- Per-org cost dashboards
- Org-level Crossplane resource hierarchies

**v0.7 — Advanced agent patterns**:
- Adversarial debate agents (RFC Companion variant)
- Plan-and-execute decomposition for complex multi-step questions

**v0.8 — Production agent fleet operations**:
- Agent versioning and canary rollout
- Agent dependency graph and impact analysis
- Audit log of every agent action

---

## 12. Don'ts

These are guardrails for the implementation phase. If you find yourself doing one of these, stop and reconsider.

**Don't add features that the developer form doesn't expose.** Every feature must trace back to a form field or a platform-level decision. If a feature has no path to the user, it shouldn't be in the MVP.

**Don't add KBs, knowledge sources, or document indexing beyond the dataset profiles.** Re-adding it is regression.

**Don't add LiteLLM, vault, or self-hosted Langfuse "just in case".** They were deliberately removed.

**Don't expose multiple agent options to the developer.** No "vector store dropdown", no "embedding model dropdown", no "chunking strategy". Platform decides; developer accepts.

**Don't try to make the architecture provider-agnostic with abstractions.** It's GCP. Hardcode it.

**Don't enable agents to call arbitrary tools.** The agent's MCP tools are exclusively: `dataset.read_profile`, `sandbox.execute_python`, `langfuse.log_observation`. Any new tool addition is a deliberate decision, not a casual change.

**Don't build a chat UI that's general-purpose.** The chat is purpose-built for "user asks dataset question, gets text + chart". Don't make it a generic chat app.

**Don't let the sandbox pull packages at runtime.** Every package the analyst can import is in the base image.

**Don't hand-craft Agent YAML during development.** The Backstage template is the only way to create agents. If the template can't produce a configuration, the template is missing a field — fix the template, don't bypass it.

**Don't share credentials across agents.** Each agent has its own GCP service account, mounted only in its own namespace. The sandbox receives credentials per-execution and discards them after.

**Don't reuse names or skip the random suffix.** Bucket names are globally unique in GCS; the suffix prevents collisions on agent recreation.

---

## 13. Acceptance criteria

The MVP is complete when:

1. `make deploy` provisions the entire stack on a fresh GCP project in under 20 minutes
2. The Backstage template successfully creates a working Dataset Whisperer agent in under 90 seconds (PR to chat-ready)
3. Each agent has its own dedicated namespace, GCS bucket, and GCP service account, all named with the `{agent-name}-{xyz}` convention
4. The chat interface responds to queries about all three datasets with text + working chart
5. Charts uploaded to per-agent buckets are correctly served via signed URLs
6. Langfuse traces show three distinct A2A spans per query, tagged with the agent's full identifier
7. Grafana dashboards display real data for platform health, cost, performance, sandbox, and Crossplane reconciliation
8. Kyverno policies block at least one demonstrable bad configuration
9. `make destroy` cleanly tears down all GCP infrastructure including all per-agent resources
10. The README's quickstart works end-to-end on a developer's first attempt
