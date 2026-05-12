# Dataset Whisperer — Backstage Template

This Backstage template provisions a fully governed **Dataset Whisperer** agent with a 4-field form. In under 90 seconds of ArgoCD sync time, it creates:

- A dedicated Kubernetes namespace (`agent-{name}`)
- Three kagent Agent CRDs: Planner, Analyst, and Writer — all using a single unified ModelConfig (`model`) backed by Vertex AI Gemini 2.5 Flash
- A per-agent GCS bucket for chart artifacts
- IAM bindings: `objectViewer` on shared datasets bucket, `objectAdmin` on per-agent bucket
- A Crossplane `ServiceAccountKey` materialising a K8s Secret
- A sandboxed Python execution environment (per-agent sandbox pod in `agent-{name}` namespace)
- A chat frontend with a public HTTPS ingress at `agent-{name}.{baseDomain}`
- Kyverno network policies (egress allowlist: sandbox, Supabase, Vertex AI, DNS)
- Budget-controller integration via `whisperops.io/budget-usd` annotation

## Scaffolded Repo Layout

Each scaffolded agent repo has a two-level layout:

```
agent-{name}/
  catalog-info.yaml      # Backstage Component — stays at root; invisible to ArgoCD
  manifests/             # ArgoCD sync path — only K8s resources here
    namespace.yaml
    bucket.yaml
    service-account.yaml
    service-account-key.yaml
    iam-bindings.yaml
    modelconfig.yaml          # unified Vertex AI Gemini 2.5 Flash ModelConfig
    agent-planner.yaml
    agent-analyst.yaml
    agent-writer.yaml
    toolserver-sandbox.yaml
    sandbox.yaml
    kyverno-policy.yaml
    chat-frontend.yaml
    ingress.yaml
    argocd-app.yaml
```

ArgoCD Application `spec.source.path` is `manifests`, so it never tries to apply
`catalog-info.yaml` as a K8s resource (which previously produced a CRD-not-found
OutOfSync error for every new scaffold).

## Form Fields

| Field | Required | Description |
|-------|----------|-------------|
| `agent_name` | Yes | Slug, `^[a-z][a-z0-9-]{2,28}[a-z0-9]$` |
| `description` | Yes | Free-text description (max 200 chars) |
| `dataset_id` | Yes | One of: `california-housing`, `online-retail-ii`, `spotify-tracks` |
| `budget_usd` | No | Max spend in USD (default `5.00`, format: `\d+\.\d{2}`) |

`base_domain` and `project_id` are hidden fields, sed-baked into `template.yaml`
by `_vm-bootstrap` from the live VM IP and project ID at deploy time. Operators
never type them.

## Model Configuration

All three agent roles (Planner, Analyst, Writer) share a single `ModelConfig` CR named `model`:

- **Provider:** `GeminiVertexAI` (kagent v1alpha1)
- **Model:** `gemini-2.5-flash` (sliding alias, us-central1)
- **Auth:** `kagent-vertex-credentials` Secret, Reflector-replicated from `kagent-system`
- **ProjectID:** baked from `project_id` at scaffold time

## Sync Wave Order

| Wave | Resources |
|------|-----------|
| 0 | Namespace, ESO ExternalSecret, ArgoCD Application |
| 1 | Crossplane Bucket, ServiceAccount, ServiceAccountKey, IAM bindings; ModelConfig |
| 2 | kagent Agents (×3), ToolServer, Kyverno Policy |
| 3 | Chat-frontend HelmRelease, Ingress |

## Budget Enforcement

The `budget-controller` polls Langfuse every 60 seconds. When an agent reaches 80% of its budget, a Kubernetes Event and Prometheus counter are emitted. At 100%, all Deployments in the agent namespace are scaled to 0. The operator can re-enable an agent by updating the budget annotation and triggering an ArgoCD re-sync.

The budget-controller computes cost from the Vertex AI Gemini 2.5 Flash pricing table:
`$0.30 / $2.50 / $0.03` per 1M input / output / cached-input tokens.

## Dataset Details

| Dataset | CSV Filename (flat bucket key) | Archetype | Size |
|---------|-------------------------------|-----------|------|
| `california-housing` | `california-housing-prices.csv` | regression | 1.4 MB |
| `online-retail-ii` | `online_retail_II.csv` | time-series | 95 MB |
| `spotify-tracks` | `spotify-tracks.csv` | exploratory | 20 MB |
