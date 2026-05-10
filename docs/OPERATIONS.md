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
| `secrets/{anthropic,langfuse,openai,supabase}.enc.yaml` present and SOPS-encrypted | Yes | `grep -l '^sops:' secrets/*.enc.yaml | wc -l` → 4 |
| `terraform/envs/demo/{terraform,backend}.tfvars` customised (no `YOUR_GCP_PROJECT_ID` placeholders) | Yes | `make preflight` |
| Tooling locally: `terraform>=1.7`, `gcloud`, `age`, `sops`, `kubectl>=1.29`, `helm>=3.14`, `helmfile>=0.163`, `make`, `node>=20`, `python3.12`, `yq`, `jq` | Yes | `which yq jq` |
| `cnoe.localtest.me` resolves to `127.0.0.1` | Yes | `dig +short cnoe.localtest.me` |
| Local clock not skewed (SOPS will refuse decrypts otherwise) | Yes | `sudo systemctl status systemd-timesyncd` (Linux) / `sntp -sS time.apple.com` (macOS) |

To decrypt secrets to plaintext siblings for inspection (gitignored):

```bash
make decrypt-secrets
# Produces secrets/{anthropic,langfuse,openai,supabase}.dec.yaml
```

You don't need this for the deploy — `_vm-bootstrap` and the secret Make targets decrypt on demand.

### The rollup

```bash
export SOPS_AGE_KEY_FILE=$PWD/age.key
gcloud auth application-default login

make deploy
```

`make deploy` invokes six sub-targets sequentially. Each has its own readiness sentinel; the chain is robust against tf-apply→VM-ready and idpbuilder timing.

| Step | What it does | Time |
|---|---|---|
| **preflight** | Verifies gcloud auth, tfvars placeholders cleared, age.key readable, all four SOPS files encrypted, tfstate bucket exists, `cnoe.localtest.me → 127.0.0.1` | ~5 s |
| **tf-apply** | Provisions VM + VPC + AR repo + bootstrap SA (with IAM bindings) + datasets bucket + per-deploy external IP + firewall rules | ~3 min |
| **upload-datasets** | Uploads `datasets/*.csv` to `gs://<project>-datasets/` (idempotent via `--no-clobber`) | ~30 s |
| **copy-repo** | rsync repo to `/tmp/whisperops` on the VM. Polls SSH:22 up to 5 min — `tf-apply` returns before sshd is ready | ~1 min |
| **gcp-bootstrap-key** | Generates fresh SA key, scp's to VM, applies as Secret `gcp-bootstrap-sa-key` in `crossplane-system`. Waits up to 20 min for cloud-init to ready kubectl + sudo NOPASSWD + cluster API. | ~10 s after wait |
| **build-images** | SSH to VM, build 4 whisperops images (`budget-controller`, `platform-bootstrap`, `sandbox`, `chat-frontend`), push to Artifact Registry | ~5 min |
| **deploy-vm** | SSH to VM, run `_vm-bootstrap` inside. Polls `/var/log/whisperops-bootstrap.log` for "whisperops bootstrap complete" sentinel up to 25 min — the startup-script does `idpbuilder create` and an ArgoCD-Synced/Healthy gate. Then helmfile apply, push the repo + root-app to in-cluster Gitea, materialize `langfuse-credentials` and `anthropic-api-key` Secrets, sync Backstage templates with sed-baked `base_domain` + `project_id`, regenerate external Ingresses, update the `platform-config` ConfigMap. | ~10-15 min |

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
| `kagent` pod `CrashLoopBackOff` immediately after deploy | `anthropic-api-key` Secret missing or unreadable | `kubectl get secret anthropic-api-key -n kagent-system`; re-run `_anthropic-secret` Make target manually if needed |

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
7. Sync wave order: Namespace → Crossplane resources → kagent ModelConfig + Agent CRs → Sandbox + chat-frontend.
8. Once ArgoCD reports the new Application `Synced/Healthy` (≤ 90 s), browse to `https://agent-{name}.${VM_IP}.sslip.io:8443/`. Ask a question.

Note that `base_domain` and `project_id` are NOT user-visible form inputs — `_vm-bootstrap` sed-bakes the live VM IP and project ID into the template before pushing it to Gitea.

### Watching reconciliation

```bash
# All applications
kk 'sudo kubectl get applications -n argocd'

# A specific app
kk "sudo kubectl describe application agent-{name} -n argocd"

# Per-agent Crossplane resources
kk "sudo kubectl get bucket,serviceaccount.cloudplatform.gcp.upbound.io,serviceaccountkey,projectiammember,modelconfig.kagent.dev,agent.kagent.dev -n agent-{name}"

# kagent runtime tail
kk 'sudo kubectl logs -n kagent-system -l app=kagent --tail=50 -f'

# Chat-frontend pod for the new agent
kk "sudo kubectl get pods,svc,ingress -n agent-{name}"
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

Four whisperops dashboards (under "Dashboards"):

| Dashboard | What it shows | Primary datasources |
|---|---|---|
| **Platform Health** | Pod readiness, resource utilization, ArgoCD app health | Mimir, Loki |
| **Agent Cost** | Per-agent spend rollups (current cycle, lifetime) | Langfuse Infinity REST, Mimir |
| **Agent Performance** | A2A span latency (Planner / Analyst / Writer), p50/p95 | Tempo (TraceQL) |
| **Sandbox Execution** | Execution rate, OOM rate, timeout rate, error rate | Loki (LogQL), Tempo |

Some panels currently use Langfuse Infinity / Tempo TraceQL / Loki LogQL queries as workarounds for metrics that no v0.3 component emits natively. Plans to migrate to native PromQL once the budget-controller + sandbox emit `whisperops_*` instruments are tracked in the internal backlog.

### Tracing (Tempo)

In Grafana, **Explore → Tempo**. Each end-to-end query produces 3 A2A spans:

```
trace
├── planner (Sonnet 4.5)
│   ├── analyst (A2A call)
│   │   └── sandbox.mcp.execute_python  ← subprocess timings, code length
│   └── writer (A2A call)
```

Each span carries `agent.namespace` and `agent.name` resource attributes. Filter by them via the TraceQL query bar: `{ resource.agent.name = "spotify-explorer" }`.

> Tempo currently uses in-memory storage. Pod restart loses trace history. Durable WAL/blocks are tracked in the internal backlog.

### Langfuse Cloud (LLM ops)

`https://us.cloud.langfuse.com/`. Same traces as Tempo, but with LLM-specific views:

- **Traces** tab — token counts, cost per call, prompts, completions.
- **Sessions** tab — multi-turn conversations grouped by `session.id`.
- **Scores** tab — annotation rollups (if any).

Filter by `whisperops.agent.id` tag to scope to one agent.

> The Langfuse Cloud free tier (50k events/month) may be exhausted under heavy iteration. Three mitigations are tracked in the internal backlog: SDK sampling, self-host Langfuse via Helm, and trace filtering.

### Logs (Loki)

In Grafana, **Explore → Loki**. Useful queries:

```logql
# All sandbox execution errors across all agents
{namespace=~"agent-.+", container="sandbox"} |= "ERROR"

# Per-agent OTel collector traffic
{namespace="observability", container="otel-collector"} |~ "agent.name=spotify-explorer"

# kagent reconciliation events
{namespace="kagent-system"} |= "reconcile"
```

### Metrics (Mimir)

In Grafana, **Explore → Mimir**. Existing metrics include `kube_pod_*`, `container_*`, `kagent_*` (where the kagent chart emits them), and standard cluster metrics. Native `whisperops_*` metrics (sandbox executions, budget spend gauges) are tracked in the internal backlog.

### Cross-references

- [`ARCHITECTURE.md`](ARCHITECTURE.md) — what each component does and how the data flows
- [`SECRETS.md`](SECRETS.md) — SOPS + age workflow, what each Secret holds
- [`SECURITY.md`](SECURITY.md) — threat model, IAM scoping, residual risks
- [`runbooks/incident-response.md`](runbooks/incident-response.md) — incident procedures for budget breach, sandbox failures, Crossplane stuck, platform unreachable
