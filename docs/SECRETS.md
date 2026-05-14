# Credentials Inventory

> Every credential whisperops uses at runtime: what it is, where it comes from, where it lands in the cluster, and how it rotates.

There is **no SOPS** in the current setup. There is **no `secrets/` directory**. Every credential is one of:

| Class | Source | Lifetime |
|---|---|---|
| **Terraform-issued SA keys** | `gcloud iam service-accounts keys create` invoked by a Makefile target reading a Terraform-managed SA | One per `make deploy` (ephemeral) |
| **Terraform-issued random passwords** | `random_password` / `random_id` resources in `terraform/observability.tf` | Stable across deploys; rotates only on explicit `terraform taint` |
| **Application keys issued in-cluster** | Operator signs up + creates an API key inside a self-hosted application (Langfuse) | Persists as long as the application's Postgres data persists |
| **Token-rotation Secrets** | A CronJob in `crossplane-system` refreshes the Secret on a fixed cadence | Refreshes every 30 min |

The whole credential surface fits on one page. Read this top-to-bottom to know exactly what's in the cluster.

---

## 1. GCP service-account keys (ephemeral, regenerated per deploy)

All five follow the same pattern: Terraform creates the SA + IAM bindings; a Makefile target runs `gcloud iam service-accounts keys create`, scp's the JSON to the VM, and applies it as a Kubernetes Secret. Old keys auto-prune to the 3 newest before each generation to stay under GCP's 10-keys-per-SA cap.

| Makefile target | SA email pattern | K8s Secret | Namespace | Replicated to | Consumed by |
|---|---|---|---|---|---|
| `make gcp-bootstrap-key` | `whisperops-bootstrap@…` | `gcp-bootstrap-sa-key` | `crossplane-system` | — | Crossplane providers via ProviderConfig |
| `make kagent-vertex-key` | `whisperops-kagent-vertex@…` | `kagent-vertex-credentials` | `kagent-system` | `agent-*` (Reflector) | kagent controller for Vertex Gemini Flash inference |
| `make tempo-gcs-key` | `whisperops-tempo-writer@…` | `tempo-gcs-credentials` | `observability` | — | Tempo writes WAL + blocks to `gs://whisperops-tempo-blocks/` |
| `make grafana-gcm-key` | `whisperops-grafana-gcm@…` | `grafana-gcm-credentials` | `observability` | — | Grafana GCP Cloud Monitoring datasource |
| `make langfuse-pg-key` | `whisperops-langfuse-pg-proxy@…` | `langfuse-postgres-credentials` | `observability` | — | Cloud SQL Auth Proxy sidecar in `langfuse-web` + `langfuse-worker` pods |

**Rotation:** every `make deploy` issues a fresh key, applies it, and prunes the oldest GCP keys to the newest 3 per SA. There is no rotation runbook — the deploy *is* the rotation.

**Why ephemeral:** every `tf-apply` may recreate the SA (especially the bootstrap SA whose policy mutates), so any stored key would go stale within one cycle. Per CLAUDE.md gotcha #10.

---

## 2. Terraform random-password resources (stable across deploys)

These exist for the Langfuse self-hosted Postgres backing (`whisperops-langfuse-pg`). Generated once by Terraform, written to tfstate, and consumed via Terraform outputs. They survive across destroys+deploys **as long as the tfstate bucket survives**.

| Terraform resource | Purpose | Surfaced via |
|---|---|---|
| `random_password.langfuse_db` | Postgres password for the `langfuse` database user | Bundled into `langfuse_pg_database_url` output (sensitive) |
| `random_password.langfuse_nextauth_secret` | NextAuth.js session signing secret in the Langfuse web pod | Output `langfuse_nextauth_secret` (sensitive) |
| `random_id.langfuse_encryption_key` (64-char hex) | At-rest encryption key for Langfuse-stored secrets (trace payloads, etc.) | Output `langfuse_encryption_key` (sensitive) |
| `random_password.langfuse_salt` | Password hashing salt for Langfuse-managed users | Output `langfuse_salt` (sensitive) |

All four are read by `make langfuse-pg-key` and folded into the 6-key `langfuse-postgres-credentials` Secret on each deploy. They do **not** rotate per deploy — only on `terraform taint random_password.<name>` followed by `make langfuse-pg-key`. The `ABANDON` deletion policy on the Cloud SQL user/database means a regular `terraform destroy` cascades cleanly without rotating these.

---

## 3. Langfuse application keys (operator-issued in-cluster, persists with PG data)

After the cluster is up, the operator port-forwards to the in-cluster Langfuse UI:

```bash
kubectl -n observability port-forward svc/langfuse-web 3000:3000
# browse http://localhost:3000 → sign up to create the first user
# → create a project → Settings → API Keys → New
```

The Langfuse UI issues:
- `pk-lf-…` (public key — embedded in client SDKs)
- `sk-lf-…` (secret key — server-side only)

These are **not** stored in SOPS, **not** in Terraform, **not** in a Makefile target. They live in the Langfuse PG database and are entered into client configs by hand (chat-frontend, sandbox, budget-controller — when the budget-controller refactor lands and it needs to call the Langfuse REST API).

**Rotation:** rotate in the Langfuse UI → update consumer configs → rolling restart.

---

## 4. Reflector-managed token (refreshes every 30 min)

| Secret | Namespace | Replicated to | Refreshed by |
|---|---|---|---|
| `ar-pull-secret-source` | `crossplane-system` | `agent-*` + `whisperops-system` (Reflector annotations) | 30-min CronJob in `crossplane-system` that runs `gcloud auth print-access-token` and patches the Secret |

This is the Artifact Registry image-pull credential. Reflector replicates the freshly-rotated token to every consumer namespace within seconds of the CronJob completing.

**Failure mode:** if the CronJob fails (e.g. bootstrap SA key expired), `imagePullSecrets: [ar-pull-secret]` references resolve to a stale token, agent + budget-controller pods enter `ImagePullBackOff`. Recovery: `make gcp-bootstrap-key` to refresh the underlying auth, then the next CronJob tick refreshes the pull-secret.

---

## 5. Two credentials that do NOT exist anywhere in this repo

To pre-empt confusion:

- **No OpenAI API key.** Gemini Flash (Vertex AI) handles inference; Vertex `text-embedding-005` will handle embeddings when the Supabase data layer ships. The Vertex SA (`whisperops-kagent-vertex`) authenticates both via the same JSON key.
- **No Supabase SaaS keys.** The previous SaaS-Supabase integration was retired on 2026-05-14 (see [`PENDING_whisperops.md §C1 + §C4`](../.claude/sdd/features/PENDING_whisperops.md)). A future self-hosted Supabase data layer (sketched in [`notes/supabase-data-layer-idea.md`](../notes/supabase-data-layer-idea.md)) will reuse the in-cluster Postgres pattern, not SaaS keys.

---

## 6. Tear-down

To wipe all credentials from a running cluster (e.g. when rotating compromised SA keys):

```bash
# Kubernetes Secrets — these will be recreated by the next `make deploy`
kubectl -n kagent-system delete secret kagent-vertex-credentials
kubectl -n observability delete secret \
    tempo-gcs-credentials grafana-gcm-credentials langfuse-postgres-credentials
kubectl -n crossplane-system delete secret gcp-bootstrap-sa-key ar-pull-secret-source

# Reflector-replicated copies in agent-* and whisperops-system will be re-created
# automatically once the source Secrets are re-applied.

# GCP-side SA keys — list and delete obsolete ones (deploy auto-prunes to 3 newest,
# but full revocation requires explicit gcloud delete):
for sa in whisperops-bootstrap whisperops-kagent-vertex whisperops-tempo-writer \
          whisperops-grafana-gcm whisperops-langfuse-pg-proxy; do
    gcloud iam service-accounts keys list --iam-account="${sa}@${PROJECT_ID}.iam.gserviceaccount.com" \
        --filter='~googleManaged' --format='value(name)' | xargs -I {} \
        gcloud iam service-accounts keys delete {} --iam-account="${sa}@${PROJECT_ID}.iam.gserviceaccount.com" --quiet
done

# Langfuse application keys — rotate in the UI: Settings → API Keys → Revoke
```

---

## 7. Reference

- [`OPERATIONS.md`](OPERATIONS.md) — operator handbook (deploy chain, agent lifecycle)
- [`SECURITY.md`](SECURITY.md) — threat model, IAM scoping, residual risks
- [`Makefile`](../Makefile) — `gcp-bootstrap-key`, `kagent-vertex-key`, `tempo-gcs-key`, `grafana-gcm-key`, `langfuse-pg-key` targets
- [`terraform/observability.tf`](../terraform/observability.tf) — random-password resources + Cloud SQL config
- [`DESIGN_whisperops.md`](../.claude/sdd/features/DESIGN_whisperops.md) — full security model and architecture
