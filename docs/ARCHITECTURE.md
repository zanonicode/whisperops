# Architecture

## Overview

WhisperOps is an Internal Developer Platform that provisions governed, observable Data Analyst agents over curated datasets. Operators use a 4-field Backstage form to spin up a complete agent system (Planner + Analyst + Writer) in under 90 seconds of ArgoCD sync time.

## Layer Diagram

```
EXTERNAL
  Anthropic API (Haiku/Sonnet)
  OpenAI API (text-embedding-3-small)
  Supabase Cloud (Postgres + pgvector)
  Langfuse Cloud (LLM traces + cost)
  Let's Encrypt (TLS via cert-manager)
  Operator (gcloud, age key, kubectl)

GCP PROJECT (Terraform-managed)
  VPC + subnet + firewall + static IP + sslip.io DNS
  GCE e2-standard-8 VM (32 GB / 8 vCPU)
    kind cluster (single-node)
      IDP Layer (idpBuilder bootstrap)
        Backstage  ArgoCD  Gitea  Keycloak  ESO  cert-manager  NGINX-Ingress
      Platform Layer (Helmfile + ArgoCD app-of-apps)
        kagent  LGTM (Grafana/Loki/Tempo/Mimir)
        OTel-Collector  Kyverno  provider-gcp  Sandbox pool
      Per-Agent Layer (Backstage → Gitea → ArgoCD)
        namespace: agent-{name}-{suffix}
          Planner (Haiku)  Analyst (Haiku/Sonnet)  Writer (Haiku/Sonnet)
          Chat Frontend  Crossplane resources
```

## Component Responsibilities

### Backstage Template
Entry point for operators. A 4-field form renders 14 Nunjucks skeleton files into a Gitea PR. Custom scaffolder action `whisperops:generate-suffix` ensures namespace uniqueness.

### ArgoCD (app-of-apps)
Watches `platform/argocd/applications/` and `agents/` directories in Gitea. Sync waves ensure ordered rollout: Namespace → Crossplane resources → kagent Agents → Chat Frontend.

### kagent
Kubernetes-native LLM agent controller. Manages Agent CRDs referencing prompt ConfigMaps. Supports A2A (agent-to-agent) communication.

### Sandbox
Shared FastAPI service (`sandbox` namespace). Executes Python code submitted by the Analyst agent. Enforces: 60s CPU timeout, 3 GB memory limit (via `setrlimit`), per-execution credential injection, artifact upload to per-agent GCS bucket.

### Budget Controller
60-second poll loop. Reads Langfuse cost API per agent, compares against `whisperops.io/budget-usd` annotation. At 80%: emits K8s Warning Event + Prometheus counter. At 100%: scales all Deployments in agent namespace to 0 replicas.

### Platform Bootstrap Job
One-shot Kubernetes Job (ArgoCD sync-wave 5). Downloads CSVs from shared GCS bucket, profiles them with pandas, generates descriptions via GPT-4o-mini, embeds with `text-embedding-3-small`, upserts to Supabase pgvector. Idempotent via SHA-256 source hash.

### Observability Stack
LGTM (Grafana + Loki + Tempo + Mimir) + OTel Collector with dual exporter:
- `otlp/tempo` → in-cluster Tempo
- `otlphttp/langfuse` → Langfuse Cloud

## Data Flow: Provisioning (≤ 90s)

1. Operator fills Backstage form → scaffolder task created
2. `whisperops:generate-suffix` → random 4-char suffix
3. 14 Nunjucks files rendered → committed to Gitea `agents/{name}-{xyz}/`
4. ArgoCD detects new path → syncs in wave order
5. Wave 0: Namespace + ESO ExternalSecret + ArgoCD Application
6. Wave 1: Crossplane Bucket + ServiceAccount + ServiceAccountKey + IAM bindings
7. Wave 2: kagent Agents (×3) + ToolServer + Kyverno Policy
8. Wave 3: Chat Frontend Deployment + Service + Ingress
9. cert-manager issues TLS → `agent-{name}-{xyz}.{base_domain}` is live

## Data Flow: Query Runtime (≤ 15s p50)

1. User types question → HTTP POST `/api/chat`
2. Next.js route handler opens SSE stream → forwards to Planner agent
3. Planner (Haiku) reads dataset profile from Supabase pgvector → returns JSON plan
4. Analyst (Haiku/Sonnet) generates Python code → calls `sandbox.execute_python`
5. Sandbox: injects per-exec credentials, runs subprocess with limits, uploads chart
6. Analyst returns signed chart URL + summary
7. Writer (Haiku/Sonnet) formats prose + embeds chart → streams SSE tokens
8. Browser renders tokens incrementally; chart renders inline

## Security Controls

| Control | Implementation |
|---------|---------------|
| Network isolation | Kyverno-generated NetworkPolicy per agent namespace |
| Sandbox egress | NetworkPolicy: GCS + DNS only |
| No privilege escalation | Kyverno ClusterPolicy: `privileged: false`, `allowPrivilegeEscalation: false` |
| Secret lifecycle | SOPS → ESO → K8s Secret; SA keys written to `/tmp` and deleted in `finally` |
| Image registry allowlist | Kyverno: Gitea + approved upstreams only |
| Budget enforcement | budget-controller scales to 0 at 100% spend |
| Resource limits | Kyverno: CPU+memory limits required in agent namespaces |

## Storage Layout

```
gs://{project}-datasets/          # Shared; read by Sandbox via signed URL
  california-housing-prices.csv
  online_retail_II.csv
  spotify-tracks.csv

gs://agent-{name}-{suffix}/       # Per-agent; write artifacts
  artifacts/chart.png
  artifacts/chart.html
```
