# WhisperOps — Operations Handbook

> Operator-facing guide. Three sections:
>
> 1. **Deploy chain** — `make deploy` rollup, what each step does, recovery
> 2. **Agent lifecycle** — scaffolding an agent via Backstage; chatting; teardown
> 3. **Observability navigation** — Grafana, Tempo, Loki, Mimir, Langfuse Cloud
>
> Audience: senior platform engineer comfortable with Kubernetes, Helm, GCP, SOPS. We don't re-explain those primitives. For architectural *why* see [`ARCHITECTURE.md`](ARCHITECTURE.md) and the internal `DESIGN_whisperops.md`.

---

## §1 — Deploy chain

### Prereqs

| Item | Required | Check |
|---|---|---|
| `gcloud` authed (Application Default Credentials) | Yes | `gcloud auth application-default print-access-token` |
| Target GCP project ID known and billing enabled | Yes | `gcloud projects describe <id>` |
| Repo cloned at a stable path | Yes | `git rev-parse --show-toplevel` |
| age key at `./age.key` (root of repo) | Yes | `[ -f age.key ]` |
| `SOPS_AGE_KEY_FILE=$PWD/age.key` exported | Yes | `echo $SOPS_AGE_KEY_FILE` |
| `secrets/{langfuse,openai,supabase}.enc.yaml` present and SOPS-encrypted | Yes | `grep -l '^sops:' secrets/*.enc.yaml | wc -l` → 3 |
| `terraform/envs/demo/{terraform,backend}.tfvars` customised (no `YOUR_GCP_PROJECT_ID` placeholders) | Yes | `make preflight` |
| Tooling locally: `terraform>=1.7`, `gcloud`, `age`, `sops`, `kubectl>=1.29`, `helm>=3.14`, `helmfile>=0.163`, `make`, `node>=20`, `python3.12`, `yq`, `jq` | Yes | `which yq jq` |
| `cnoe.localtest.me` resolves to `127.0.0.1` | Yes | `dig +short cnoe.localtest.me` |
| Local clock not skewed (SOPS will refuse decrypts otherwise) | Yes | `sudo systemctl status systemd-timesyncd` (Linux) / `sntp -sS time.apple.com` (macOS) |

To decrypt secrets to plaintext siblings for inspection (gitignored):

```bash
make decrypt-secrets
# Produces secrets/{langfuse,openai,supabase}.dec.yaml
```

You don't need this for the deploy — `_vm-bootstrap` and the secret Make targets decrypt on demand.

### The rollup

```bash
export SOPS_AGE_KEY_FILE=$PWD/age.key
gcloud auth application-default login

make deploy
```

`make deploy` invokes seven sub-targets sequentially. Each has its own readiness sentinel; the chain is robust against tf-apply→VM-ready and idpbuilder timing.

| Step | What it does | Time |
|---|---|---|
| **preflight** | Verifies gcloud auth, tfvars placeholders cleared, age.key readable, three SOPS files encrypted (langfuse/openai/supabase), tfstate bucket exists, `cnoe.localtest.me → 127.0.0.1` | ~5 s |
| **tf-apply** | Provisions VM + VPC + AR repo + bootstrap SA (with IAM bindings) + Vertex AI API enable + kagent Vertex SA (`whisperops-kagent-vertex` with `roles/aiplatform.user`) + datasets bucket + per-deploy external IP + firewall rules | ~3 min |
| **upload-datasets** | Uploads `datasets/*.csv` to `gs://<project>-datasets/` (idempotent via `--no-clobber`) | ~30 s |
| **copy-repo** | rsync repo to `/tmp/whisperops` on the VM. Polls SSH:22 up to 5 min — `tf-apply` returns before sshd is ready | ~1 min |
| **gcp-bootstrap-key** | Generates fresh SA key, scp's to VM, applies as Secret `gcp-bootstrap-sa-key` in `crossplane-system`. Waits up to 20 min for cloud-init to ready kubectl + sudo NOPASSWD + cluster API. | ~10 s after wait |
| **kagent-vertex-key** | Generates fresh Vertex SA JSON key for `whisperops-kagent-vertex`, scp's to VM, applies as Secret `kagent-vertex-credentials` in `kagent-system` with Reflector annotations → replicates to `agent-*` namespaces. | ~10 s |
| **build-images** | SSH to VM, build 4 whisperops images (`budget-controller`, `platform-bootstrap`, `sandbox`, `chat-frontend`), push to Artifact Registry | ~5 min |
| **deploy-vm** | SSH to VM, run `_vm-bootstrap` inside. Polls `/var/log/whisperops-bootstrap.log` for "whisperops bootstrap complete" sentinel up to 25 min — the startup-script does `idpbuilder create` and an ArgoCD-Synced/Healthy gate. Then helmfile apply (with postRenderer injecting Vertex SA-key volume on kagent Deployment), push the repo + root-app to in-cluster Gitea, materialize `langfuse-credentials` Secret, sync Backstage templates with sed-baked `base_domain` + `project_id`, regenerate external Ingresses, update the `platform-config` ConfigMap. | ~10-15 min |

**Total clean deploy: ~25 min.** Idempotent — re-running on existing infra is a no-op except `build-images`, which always rebuilds.

### After deploy

Fetch the live values you'll need:

```bash
VM_IP=$(gcloud compute instances describe whisperops-vm --zone=us-central1-a \
  --format='value(networkInterfaces[0].accessConfigs[0].natIP)')

# Operator SSH alias (used heavily in §3)
alias kk='gcloud compute ssh whisperops-vm --zone=us-central1-a --command'

ARGOCD_PASS=$(kk 'sudo kubectl get secret -n argocd argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d')
GITEA_PASS=$(kk 'sudo kubectl get secret -n gitea gitea-credential -o jsonpath="{.data.password}" | base64 -d')
GRAFANA_PASS=$(kk 'sudo kubectl get secret -n observability lgtm-distributed-grafana -o jsonpath="{.data.admin-password}" | base64 -d')
KEYCLOAK_USER1_PASS=$(kk 'sudo kubectl get secret -n keycloak keycloak-config -o jsonpath="{.data.USER_PASSWORD}" | base64 -d')
```

Five surfaces:

| Surface | URL | Notes |
|---|---|---|
| Backstage (browser) | `https://backstage.${VM_IP}.sslip.io:8443/healthcheck` | Public healthcheck route; full login requires SSH tunnel |
| Backstage (tunnel for SSO) | `https://cnoe.localtest.me:8443/backstage` | Login `user1` / `$KEYCLOAK_USER1_PASS`; requires the tunnel below |
| ArgoCD | `https://argocd.${VM_IP}.sslip.io:8443` | `admin` / `$ARGOCD_PASS` |
| Gitea | `https://gitea.${VM_IP}.sslip.io:8443` | `giteaAdmin` / `$GITEA_PASS` |
| Grafana | `https://grafana.${VM_IP}.sslip.io:8443` | `admin` / `$GRAFANA_PASS` |

SSH tunnel for Backstage SSO via Keycloak:

```bash
gcloud compute ssh whisperops-vm --zone=us-central1-a -- -L 8443:127.0.0.1:8443
# Then browse https://cnoe.localtest.me:8443/backstage in another terminal
```

### Smoke test

```bash
make smoke-test
# Copies tests/smoke/platform-up.sh to the VM and runs it with KUBECONFIG=/root/.kube/config.
# Asserts: ArgoCD apps Synced/Healthy, platform endpoints reachable, smoke probes pass.
```

The smoke target runs on the VM via SSH because the operator's local kubectl has no context pointing at the VM's kind cluster. Running it locally fails — that is intentional.

### Recurring failure modes (current)

| Symptom | Cause | Recovery |
|---|---|---|
| `make preflight` fails with "✗ SOPS_AGE_KEY_FILE unset or unreadable" | Env var not exported | `export SOPS_AGE_KEY_FILE=$PWD/age.key` |
| `make destroy` hangs at "Waiting for Crossplane finalizers" then times out | An aborted destroy left finalizers on per-agent CRs | Force-clear finalizers per the `runbooks/incident-response.md` "Crossplane Stuck Reconciling" section, then `make destroy SKIP_CROSSPLANE=1 FORCE=1 PROJECT_ID=<id>` |
| `make deploy` from a Mac with Docker running locally — build slow / inconsistent | The build runs on the VM, not locally; local Docker is irrelevant but may cause confusion | Don't worry about local Docker; the build happens on the VM |
| All sslip.io URLs change after a destroy + redeploy | The VM external IP is allocated fresh on every `tf-apply` cycle | Fetch the new IP per the snippet above; Ingresses are regenerated automatically by `_vm-bootstrap` |
| `sops --decrypt` fails with "Error getting data key: 0 successful groups required, got 0" on a fresh laptop | Local clock skew | Resync system time (`sntp -sS time.apple.com` on macOS, `systemctl status systemd-timesyncd` on Linux) |
| `chat-frontend` pod `ImagePullBackOff` mid-day | `ar-pull-secret` token expired and Reflector hasn't replicated the refreshed copy yet | The 30-min rotation CronJob should self-heal; force-restart Reflector pods if it doesn't: `kubectl delete pod -n reflector -l app.kubernetes.io/name=reflector` |
| `kagent-controller` pod `CrashLoopBackOff` immediately after deploy | `kagent-vertex-credentials` Secret missing or not yet created | `kubectl get secret kagent-vertex-credentials -n kagent-system`; re-run `make kagent-vertex-key` if Secret is absent |

### Teardown

```bash
make destroy FORCE=1 PROJECT_ID=<project-id>
```

This runs (in order): empty all per-agent buckets, drain Crossplane CRs, drop the ArgoCD Workflows CRDs, delete orphan firewall rules, run `terraform destroy`, clean orphan IAM bindings. Total: ~5–10 min on a 3-agent cluster.

If the destroy aborts and re-runs hang on finalizers, use the recovery path:

```bash
make destroy SKIP_CROSSPLANE=1 FORCE=1 PROJECT_ID=<project-id>
# Skips Crossplane drain (orphans GCP resources); the orphan-IAM-bindings and
# orphan-firewalls steps clean them up.
```

---

## §2 — Agent lifecycle

### Scaffolding an agent

1. Open the SSH tunnel (see §1) and browse to `https://cnoe.localtest.me:8443/backstage`.
2. Log in via Keycloak SSO (`user1` / `$KEYCLOAK_USER1_PASS`).
3. **Create → Choose a template → "Dataset Whisperer"**.
4. Fill the form:
   - `agent_name` — kebab-case slug, `^[a-z][a-z0-9-]{1,30}$`. Becomes the namespace, GCS bucket, and chat hostname.
   - `description` — free text.
   - `dataset_id` — enum: `california-housing`, `online-retail-ii`, `spotify-tracks`.
   - `budget_usd` — numeric, e.g. `5.00`.
5. Submit. Backstage opens a PR in the in-cluster Gitea repo `whisperops/agent-{name}`.
6. ArgoCD detects the new path within ~30 s and syncs from `manifests/` subfolder.
7. Sync wave order: Namespace → `agent-prompts` ConfigMap (wave 0) → kagent ModelConfig (wave 1) → Agent CRs planner/analyst/writer + Kyverno Policy (wave 2) → Sandbox + chat-frontend.
8. Once ArgoCD reports the new Application `Synced/Healthy` (≤ 90 s), browse to `https://agent-{name}.${VM_IP}.sslip.io:8443/`. Ask a question. Expect **at least 3 agent pods** (`planner`, `analyst`, `writer`) in the namespace — each Agent CR gets its own Deployment in kagent v0.9.x.

Note that `base_domain` and `project_id` are NOT user-visible form inputs — `_vm-bootstrap` sed-bakes the live VM IP and project ID into the template before pushing it to Gitea.

### Watching reconciliation

```bash
# All applications
kk 'sudo kubectl get applications -n argocd'

# A specific app
kk "sudo kubectl describe application agent-{name} -n argocd"

# Per-agent Crossplane + kagent resources (expect 3 Agent CRs + 1 ModelConfig)
kk "sudo kubectl get bucket,serviceaccount.cloudplatform.gcp.upbound.io,serviceaccountkey,projectiammember,modelconfig.kagent.dev,agent.kagent.dev -n agent-{name}"

# Per-agent pods — expect ≥ 3 (planner, analyst, writer each have own Deployment)
kk "sudo kubectl get pods -n agent-{name} -l whisperops/component=agent"

# kagent controller tail
kk 'sudo kubectl logs -n kagent-system deploy/kagent-controller --tail=50 -f'

# Chat-frontend pod for the new agent
kk "sudo kubectl get pods,svc,ingress -n agent-{name}"
```

### Rotating an agent system prompt

The `agent-prompts` ConfigMap in each `agent-{name}` namespace holds `planner.md`, `analyst.md`, and `writer.md` keys. The controller polls for changes (eventual-consistency, lag up to ~2 min) and rolls the affected Deployment automatically. If you need immediate effect:

```bash
# Edit a prompt in-place (e.g. planner.md)
kk "sudo kubectl edit configmap agent-prompts -n agent-{name}"

# Force immediate rollout after edit (if not waiting for controller poll)
kk "sudo kubectl rollout restart deployment/planner -n agent-{name}"
```

### Deleting an agent

Two options:

**(a) From Backstage** — soft delete:

```bash
# Delete the agent's Gitea repo via the Gitea UI, OR via kubectl:
kk "sudo kubectl delete application agent-{name} -n argocd"
# ArgoCD prunes per-agent resources. Crossplane finalizers reconcile the GCS
# bucket and SA deletions in GCP. Allow ~30 s.
```

**(b) Manual cleanup if Crossplane is stuck** — see `runbooks/incident-response.md`.

### Common operational tasks

```bash
# Force ArgoCD re-sync (clears stale SyncFailed)
kk "sudo kubectl patch app -n argocd <name> --type merge --patch '{\"operation\":{\"sync\":{\"prune\":true}}}'"

# Hard refresh (re-pull from Git)
kk "sudo kubectl annotate app -n argocd <name> argocd.argoproj.io/refresh=hard --overwrite"

# Inspect bootstrap SA key
kk 'sudo kubectl get secret -n crossplane-system gcp-bootstrap-sa-key -o jsonpath="{.data.credentials\.json}" | base64 -d | jq -r .private_key_id'

# Compare with current GCP keys
gcloud iam service-accounts keys list --iam-account=whisperops-bootstrap@<project>.iam.gserviceaccount.com

# Force Crossplane provider pod restart (after key rotation)
kk 'sudo kubectl delete pod -n crossplane-system -l pkg.crossplane.io/provider'

# Inspect the source ar-pull-secret token (rotation status)
kk 'sudo kubectl get secret -n crossplane-system ar-pull-secret-source -o jsonpath="{.data.\.dockerconfigjson}" | base64 -d | jq'
```

---

## §3 — Observability navigation

### Grafana

`https://grafana.${VM_IP}.sslip.io:8443/`, login `admin` / `$GRAFANA_PASS`.

**Platform dashboards** (Grafana folder `platform/`):

| Dashboard | What it shows | Primary datasources |
|---|---|---|
| **Cluster Health** | Pod readiness, node CPU/memory, PVC utilization | Mimir (kube-state-metrics, node-exporter) |
| **LLM Platform Overview** | A2A latency p50/p95, token usage, request rate, error rate | Mimir (traces_spanmetrics_*, whisperops_tokens_*) |
| **SLO Compliance** | Error budget burn-down, SLO ratio trend, MWMBR alert state | Mimir (sli:* recording rules) |
| **Service Map** | Live inter-service dependency graph from Tempo span metrics | Tempo (nodeGraph) |
| **Cost and Tokens** | Per-agent cumulative spend vs budget, token input/output breakdown | Mimir (whisperops_spend_usd:cumulative) |
| **RED Method per Agent** | Rate, Errors, Duration per agent namespace | Mimir |
| **Apdex per Agent** | Apdex T=10s score per agent; satisfied/tolerable/frustrated breakdown | Mimir (sli:apdex_score recording rule) |
| **ArgoCD / Crossplane Platform Health** | ArgoCD app sync health, Crossplane provider health, Kyverno violations | Mimir |

**Per-agent detail dashboards** (Grafana folder `k8s/{agent_name}/`): provisioned automatically at agent scaffold time. Each shows availability stat, TTFT p95, budget utilization, Apdex score, sandbox execution timeseries, token usage timeseries, Loki log stream, and Tempo TraceQL panel scoped to that agent.

To navigate: Dashboards → Browse → folder `k8s/{agent_name}/` → "Agent {name} — Detail".

### SLO budget-burn troubleshooting

When an SLO alert fires (visible in Grafana Alerting → Alert rules):

1. **Identify the burn rate**: open the SLO Compliance dashboard. A fast-burn alert (14.4×, severity: page) means the budget exhausts in ~2 days. A slow-burn (6×, severity: warn) exhausts in ~5 days.
2. **Find the source**: RED Method per Agent dashboard → select the agent namespace → look for spike in error rate or latency p95.
3. **Correlate with traces**: Explore → Tempo → TraceQL `{ resource.agent_name = "<name>" && status = error }`. Click a failing trace to find the span.
4. **Follow trace→logs**: from a Tempo span, click "Logs for this span" — Grafana auto-generates a Loki query using the `trace_id` label extracted by Alloy from JSON log bodies.
5. **See runbook**: `docs/runbooks/slo-burn-alert.md` for the full triage checklist.

### Budget kill-switch

The `BudgetBurnPage` alert (in the `mimir-ruler-budget-burn` ConfigMap) fires when `whisperops_spend_usd:cumulative` for an agent reaches 100% of its `budget_usd`. The `budget-controller` polls Mimir for this alert and scales all Deployments in the agent namespace to 0 replicas.

To verify kill-switch state:

```bash
# Check firing alerts (run on VM)
kk 'sudo kubectl exec -n observability deploy/lgtm-distributed-mimir-nginx -- \
  wget -qO- http://localhost:80/prometheus/api/v1/alerts | jq ".data.alerts[] | select(.state==\"firing\")"'

# Check budget-controller logs
kk 'sudo kubectl logs -n whisperops-system deploy/budget-controller --tail=50'

# Manually un-scale an agent after budget top-up
kk 'sudo kubectl scale deploy planner analyst writer sandbox chat-frontend -n agent-{name} --replicas=1'
```

See `docs/runbooks/budget-kill-switch.md` for the full procedure.

### Per-agent dashboard discovery

Each scaffolded agent gets a dashboard ConfigMap in its own namespace at scaffold time. The Grafana sidecar auto-discovers it via the `grafana_dashboard: "1"` label. If the dashboard is missing after scaffold:

```bash
# Check ConfigMap exists
kk 'sudo kubectl get configmap {agent_name}-dashboard -n agent-{name} -o jsonpath="{.metadata.labels}"'

# Verify sidecar loaded it (look for "Dashboard added" in sidecar logs)
kk 'sudo kubectl logs -n observability -l app.kubernetes.io/name=grafana -c grafana-sc-dashboard --tail=20'
```

### Trace-to-logs join walkthrough

Grafana connects Tempo spans to Loki log lines via `tracesToLogsV2` configuration (set in lgtm-values.yaml). The join key is `trace_id`, which Alloy extracts from JSON log bodies using a `stage.json` pipeline stage.

For the join to work, three things must be true:
1. The log line must be JSON and contain a `trace_id` field.
2. Alloy must be running (DaemonSet — one pod per node).
3. The Loki label `trace_id` must match the Tempo span's `traceId`.

To verify Alloy is extracting `trace_id`:

```bash
# Alloy pod status (expect 1/1 per node)
kk 'sudo kubectl get pods -n observability -l app.kubernetes.io/name=alloy'

# Check Alloy has RBAC to list pods (required for loki.source.kubernetes)
kk 'sudo kubectl auth can-i list pods -n agent-housing-demo --as=system:serviceaccount:observability:alloy'

# Sample a log line with trace_id extraction
kk 'sudo kubectl logs -n observability -l app.kubernetes.io/name=alloy --tail=50 | grep -i trace_id'
```

### Tracing (Tempo)

In Grafana, **Explore → Tempo**. Each end-to-end query produces a span hierarchy:

```
trace
├── planner (Gemini 2.5 Flash via Vertex AI)
│   ├── analyst (A2A call → traces_spanmetrics_latency)
│   │   └── sandbox.mcp.execute_python  ← subprocess timings, code length
│   └── writer (A2A call)
```

Filter by agent: `{ resource.agent_name = "housing-demo" }`. Filter errors: `{ resource.agent_name = "housing-demo" && status = error }`.

Tempo uses GCS-backed WAL+blocks at `gs://whisperops-tempo-blocks/` (30-day lifecycle rule). The metrics-generator produces `traces_spanmetrics_calls_total` and `traces_spanmetrics_latency` — these are the SLI source for kagent A2A latency (tier A).

### Langfuse (self-hosted, LLM ops)

Langfuse is deployed in-cluster as part of the observability helmfile release. It receives traces from the OTel Collector `otlphttp/langfuse` exporter.

```bash
# Langfuse pod status
kk 'sudo kubectl get pods -n observability -l app.kubernetes.io/name=langfuse'

# Langfuse web URL (via port-forward — no Ingress by default)
kk 'sudo kubectl port-forward -n observability svc/langfuse-web 3000:3000 &'
# Then browse http://localhost:3000
```

See `docs/runbooks/langfuse-self-host-recovery.md` for pod recovery and Cloud SQL diagnostics.

### Logs (Loki)

In Grafana, **Explore → Loki**. Useful queries:

```logql
# All sandbox execution errors across all agents
{namespace=~"agent-.+", container="sandbox"} |= "ERROR"

# Logs for a specific trace ID (paste from a Tempo span)
{namespace=~"agent-.+"} | trace_id = "abc123..."

# kagent reconciliation events
{namespace="kagent-system"} |= "reconcile"

# Alloy pipeline dropped lines (debug cardinality)
{namespace="observability", app="alloy"} |= "stage.drop"
```

### Metrics (Mimir)

In Grafana, **Explore → Mimir** (datasource uid: `mimir`). Key metric namespaces:

| Prefix | Source | Examples |
|---|---|---|
| `kube_pod_*`, `kube_deployment_*` | kube-state-metrics | replica counts, container restarts |
| `node_cpu_*`, `node_memory_*` | node-exporter | host CPU/memory utilization |
| `traces_spanmetrics_*` | Tempo metrics-generator | A2A latency, call counts |
| `whisperops_tokens_*` | sandbox OTel SDK | token input/output per model |
| `sandbox_executions_total` | sandbox OTel SDK | execution outcomes (success/error) |
| `sandbox_execution_duration_*` | sandbox OTel SDK | execution latency histogram |
| `sli:*` | Mimir Ruler recording rules | pre-computed SLI ratios |
| `whisperops_spend_usd:cumulative` | Mimir Ruler recording rules | per-agent daily spend USD |

### Cross-references

- [`ARCHITECTURE.md`](ARCHITECTURE.md) — what each component does and how the data flows
- [`SECRETS.md`](SECRETS.md) — SOPS + age workflow, what each Secret holds
- [`SECURITY.md`](SECURITY.md) — threat model, IAM scoping, residual risks
- [`runbooks/budget-kill-switch.md`](runbooks/budget-kill-switch.md) — budget breach → scale-to-zero procedure
- [`runbooks/slo-burn-alert.md`](runbooks/slo-burn-alert.md) — SLO burn alert triage
- [`runbooks/langfuse-self-host-recovery.md`](runbooks/langfuse-self-host-recovery.md) — Langfuse pod + Cloud SQL recovery
- [`runbooks/incident-response.md`](runbooks/incident-response.md) — Crossplane stuck, platform unreachable
