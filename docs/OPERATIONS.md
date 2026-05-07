# WhisperOps — Operations Handbook

> Canonical operator-facing guide for the v0.3 prototype. Reflects DESIGN v1.10 (DD-1 through DD-36) and the v1.4 live-deploy reconciliation. Three sections:
>
> 1. **End-to-end deploy guide** — Stage 0 (preflight) through Stage 9 (first agent)
> 2. **Backstage deploy + agent interaction** — using the platform once it's up
> 3. **Observability navigation** — Grafana, Tempo, Loki, Mimir, Langfuse Cloud
>
> Audience: senior platform engineer comfortable with Kubernetes, Helm, GCP, SOPS. We don't re-explain those primitives. Cross-reference DESIGN decisions (DD-NN) for *why*; this doc explains *how*.

---

## §1 — End-to-end deploy guide

### Prereqs

Verify each before Stage 0. Most are checked by `make preflight`.

| Item | Required | Check |
|---|---|---|
| `gcloud` authed (Application Default Credentials) | Yes | `gcloud auth application-default print-access-token` |
| Target GCP project ID known and billing enabled | Yes | `gcloud projects describe <id>` |
| Repo cloned at a stable path | Yes | `git rev-parse --show-toplevel` |
| age key at `./age.key` (root of repo) | Yes | `[ -f age.key ]` |
| `SOPS_AGE_KEY_FILE=$PWD/age.key` exported | Yes | `echo $SOPS_AGE_KEY_FILE` |
| `secrets/*.enc.yaml` present and SOPS-encrypted (anthropic, openai, supabase, langfuse, crossplane-gcp-creds) | Yes | `grep -l '^sops:' secrets/*.enc.yaml \| wc -l` → 5 |
| `terraform.tfvars` and `backend.tfvars` customised (no `YOUR_GCP_PROJECT_ID` placeholders) | Yes | `make preflight` |
| Tooling on local machine: `terraform>=1.7`, `gcloud`, `age`, `sops`, `kubectl>=1.29`, `helm>=3.14`, `helmfile>=0.163`, `make`, `node>=20`, `python3.12`, `yq` (DD-31), `jq` | Yes | `which yq jq` |
| `cnoe.localtest.me` resolves to `127.0.0.1` (mandatory since DD-38 — required for SSH-tunnel access to Keycloak/Backstage) | Yes | `dig +short cnoe.localtest.me` |
| Local clock not skewed (SOPS will refuse decrypts otherwise) | Yes | `sudo systemctl status systemd-timesyncd` (Linux) / `sntp -sS time.apple.com` (macOS) |

To decrypt a secret to its plaintext sibling for inspection (gitignored):

```bash
make decrypt-secrets
# Produces secrets/{anthropic,openai,supabase,langfuse,crossplane-gcp-creds}.dec.yaml
```

You don't need to do this for the deploy — the Makefile and `kubectl create secret` flows below decrypt on demand.

### Stage 0 — preflight

```bash
# From repo root.
export SOPS_AGE_KEY_FILE=$PWD/age.key
make preflight
```

Confirms gcloud auth, tfvars customisation, required GCP APIs enabled (compute, storage, iam, iamcredentials), tfstate bucket exists, DNS, age key, and all five SOPS files. **All seven checks must pass before continuing.**

### Stage 1 — cloud floor (Terraform)

Provisions everything in DD-14 + DD-19's "TF tier":

- VPC + subnet + firewall (22 from your CIDR, 80/443/8443 from 0.0.0.0/0 — port 8443 covers DD-23 ingress)
- Static external IP + GCE `e2-standard-8` VM (`whisperops-vm`, `ubuntu-2204-lts`) with the idpbuilder bootstrap script as user-data
- Shared GCS buckets: `{project}-tfstate`, `{project}-datasets`
- Bootstrap GCP service account `whisperops-bootstrap@{project}.iam.gserviceaccount.com` with `iam.serviceAccountAdmin`, `iam.serviceAccountKeyAdmin`, `resourcemanager.projectIamAdmin`, `storage.admin`, `artifactregistry.writer` — all unconditional per DD-19 (IAM Conditions don't gate `*.create` operations because `resource.name` is empty at create time; conditions were security-theatre)
- Artifact Registry repo `whisperops-images` (DD-14)

```bash
make tf-apply
terraform -chdir=terraform output -raw vm_external_ip
terraform -chdir=terraform output -raw registry_url
```

`tf-apply` reads `project_id` from `terraform/envs/demo/terraform.tfvars` (validated by `make preflight`), so no CLI variable is required.

Capture both outputs — you'll need them in Stages 4, 5, and 7.

### Stage 2 — VM bootstrap (IDP layer)

The startup script installs Docker + idpbuilder and runs `idpbuilder create --use-path-routing`, which deploys the CNOE ref-implementation (`platform/idp/`, vendored): ArgoCD, Gitea, Backstage, External Secrets Operator, NGINX Ingress, cert-manager, metric-server, spark-operator. Keycloak is included but scaled to zero (DD-33); argo-workflows is removed (DD-35). Wait roughly 6–8 minutes after `tf-apply` returns.

```bash
gcloud compute ssh whisperops-vm --zone=us-central1-a -- \
  'sudo kubectl --kubeconfig=/root/.kube/config get applications -n argocd'
# Expect: 8-9 apps Synced/Healthy
```

The `/root/.kube/config` fallback in `terraform/files/startup-script.sh` exists because idpbuilder's HOME-detection writes the kubeconfig to `/.kube/config` when run under systemd (HOME=/) — the script symlinks the result to `/root/.kube/config` so subsequent `kubectl` commands work without `--kubeconfig` on the VM if you `sudo -i` first.

**Known recurring failure:** the CNOE Keycloak config-job is non-idempotent — if it crashes between realm creation and Secret creation, the next run sees the realm and exits 0 without producing the `keycloak-clients` Secret. Recovery: `kubectl delete ns keycloak && argocd app sync keycloak`.

### Stage 3 — copy whisperops repo to the VM

The application platform layer runs `helmfile apply` from inside the VM; helmfile resolves value-file refs (`platform/values/*.yaml`, `platform/observability/*.yaml`) relative to the file. Use `make copy-repo` (DD-34) to push the repo:

```bash
make copy-repo
# Tars the repo (excluding .terraform, .git, node_modules, secrets/*.dec.yaml,
# __pycache__, dist) and streams it via gcloud compute ssh into /tmp/whisperops
# on whisperops-vm.
```

### Stages 4–7 — Recommended bring-up

After Stage 3, the full inside-VM sequence (helmfile apply, Keycloak scale-to-zero, Backstage host rewrite, secrets, ingresses, platform-config, platform-bootstrap) is automated by `make deploy-vm` (DD-34):

```bash
make copy-repo && make deploy-vm
```

`deploy-vm` SSHes into `whisperops-vm` and runs `make _vm-bootstrap`, which:

1. Derives `VM_IP` from the GCP metadata server (no Terraform state needed on the VM)
2. Rewrites all `cnoe.localtest.me` references in `platform/idp/backstage/manifests/install.yaml` to sslip.io URLs (`platform/scripts/rewrite-backstage-hosts.sh`, DD-36)
3. Runs `helmfile -f platform/helmfile.yaml.gotmpl apply`
4. Scales Keycloak to 0 replicas (`platform/values/keycloak-postrender.sh`, DD-33 — Keycloak OIDC is disabled; Backstage uses guest auth)
5. Materializes the `langfuse-credentials` Secret (`make langfuse-secret`)
6. Regenerates and applies external Ingresses (`make external-ingresses`)
7. Updates the `platform-config` ConfigMap with `base_domain` and `registry_url`
8. Runs the platform-bootstrap Job (`make platform-bootstrap`)

The firewall rule `allow-kind-ingress` (TCP/8443) is now Terraform-managed (DD-39). It is created automatically by `make tf-apply`.

After `deploy-vm` completes, proceed to Stage 5 (secrets materialization) on your local workstation.

### Manual bring-up (for debugging)

Use this step-by-step sequence when `make deploy-vm` fails partway and you need to resume from a specific point.

#### Stage 4 — application platform layer (helmfile)

SSH in, install helm + helmfile if absent, then apply. Per DD-27, this is the **official v0.3 deploy mechanism** for the platform layer — ArgoCD's `root-app.yaml` is a v0.4 stub.

```bash
gcloud compute ssh whisperops-vm --zone=us-central1-a
# On the VM:
sudo -i
cd /tmp/whisperops

# Pre-create the kagent namespace (chart hardcodes some resources to it)
kubectl --kubeconfig=/root/.kube/config create ns kagent
kubectl --kubeconfig=/root/.kube/config create ns kagent-system
kubectl --kubeconfig=/root/.kube/config create ns observability

# Rewrite Backstage hosts before applying (DD-36)
VM_IP=$(curl -sf -H "Metadata-Flavor: Google" \
  http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip)
bash platform/scripts/rewrite-backstage-hosts.sh "$VM_IP"

# Apply
KUBECONFIG=/root/.kube/config helmfile -f platform/helmfile.yaml.gotmpl apply

# Scale Keycloak to 0 (DD-33)
bash platform/values/keycloak-postrender.sh
```

Expected releases (5 + 1):

| Release | Namespace | Source | Purpose |
|---|---|---|---|
| `crossplane` | crossplane-system | upstream Helm | Per-agent GCP resources via family providers (DD-2, DD-12) |
| `kyverno` | kyverno | upstream Helm | Policy enforcement |
| `lgtm-distributed` | observability | grafana Helm | Loki + Mimir + Grafana (Tempo sub-chart **disabled** per DD-30) |
| `opentelemetry-collector` | observability | upstream Helm | Trace pipeline (dual-export per DD-24/v1.6) |
| `kagent` | kagent-system | OCI `ghcr.io/kagent-dev/kagent/helm/kagent` | Agent runtime (postRender per DD-31) |
| `tempo-mono` | observability | grafana Helm v1.18.0 | **Standalone single-binary Tempo** — sole tracing backend (DD-21, DD-30) |

The kagent release is layered with `platform/values/kagent-values.yaml` (declarative `ANTHROPIC_API_KEY` injection per DD-20) and the postRender script `platform/values/kagent-postrender.sh` (DD-31, requires `yq` on PATH) which guarantees exactly one `AUTOGEN_DISABLE_RUNTIME_TRACING=false` env entry on the rendered Deployment.

Verify:

```bash
kubectl --kubeconfig=/root/.kube/config get pods -A | grep -E 'crossplane|kyverno|kagent|otel|tempo|grafana|mimir|loki'
kubectl --kubeconfig=/root/.kube/config get providers.pkg.crossplane.io
# Expect: provider-gcp-storage, provider-gcp-iam, provider-gcp-cloudplatform, provider-family-gcp — all Healthy=True
```

#### Stage 5 — secrets materialization (order matters)

Run from your **local workstation** (where SOPS has the age key), not the VM. `kubectl` here uses your local kubeconfig pointing at the VM cluster — set up an SSH tunnel or scp `~/.kube/config` from `/tmp/whisperops/` first.

> **Bringing your own credentials?** See [docs/SECRETS.md](SECRETS.md) for how to generate an `age.key`, point `.sops.yaml` at it, and rebuild each `secrets/*.enc.yaml` from your own Anthropic / OpenAI / Langfuse / GCP / Supabase keys before running the steps below.

##### 5a — Crossplane GCP credentials (must be first; providers can't reconcile without it)

```bash
SOPS_AGE_KEY_FILE=$PWD/age.key sops --decrypt secrets/crossplane-gcp-creds.enc.yaml \
  | kubectl apply -n crossplane-system -f -
kubectl apply -f platform/crossplane/provider-config.yaml
```

> **Newline corruption gotcha (recurring):** the SOPS-decrypted JSON inside `gcp_service_account_key_json` may emerge with literal newlines inside the `private_key` string. If Crossplane's ProviderConfig logs `error unmarshaling credentials: invalid character '\n' in string literal`, run the parse-and-reescape repair pass from `docs/NEXT_STEPS.md §0.6` before applying.

##### 5b — Langfuse credentials (DD-29)

```bash
make langfuse-secret
# Decrypts secrets/langfuse.enc.yaml, derives LANGFUSE_OTLP_ENDPOINT and
# LANGFUSE_BASIC_AUTH, applies langfuse-credentials Secret in observability ns.
```

This Secret is consumed by the OTel collector's `otlphttp/langfuse` exporter (`extraEnvs` with `optional: true`) and by Grafana's `envFromSecret` for the Infinity datasource. Rerun any time Langfuse keys rotate.

##### 5c — Anthropic API key (kagent app container, DD-20)

```bash
SOPS_AGE_KEY_FILE=$PWD/age.key sops --decrypt secrets/anthropic.enc.yaml \
  | yq '.ANTHROPIC_API_KEY' \
  | xargs -I{} kubectl create secret generic anthropic-api-key \
      -n kagent-system --from-literal=api-key={} \
      --dry-run=client -o yaml | kubectl apply -f -
```

Restart kagent so the env var picks up: `kubectl rollout restart deploy/kagent -n kagent-system`.

##### 5d — OpenAI API key (kagent UI sidecar)

```bash
SOPS_AGE_KEY_FILE=$PWD/age.key sops --decrypt secrets/openai.enc.yaml \
  | yq '.OPENAI_API_KEY' \
  | xargs -I{} kubectl create secret generic kagent-openai \
      -n kagent-system --from-literal=OPENAI_API_KEY={} \
      --dry-run=client -o yaml | kubectl apply -f -
kubectl rollout restart deploy/kagent -n kagent-system
```

The `kagent` Deployment will go from 4/5 ready to 5/5 once `kagent-openai` exists (the querydoc UI sidecar requires it).

#### Stage 6 — datasets upload

```bash
make upload-datasets PROJECT_ID=<your-project-id>
# Copies datasets/*.csv to gs://<project-id>-datasets/
```

The three curated CSVs ship with the repo. Any additional dataset must be added under `datasets/`, then the platform-bootstrap Job re-run (`make regenerate-profiles`) to compute its profile JSON.

#### Stage 7 — external access (DD-23, DD-26)

The CNOE NGINX ingress maps host `:8443` to kind container `:443`. Use sslip.io for wildcard DNS that requires no DNS configuration.

```bash
# Generate Ingress manifests for the current VM IP and apply
VM_IP=$(terraform -chdir=terraform output -raw vm_external_ip)  # DD-39: now returns the VM's live NAT IP
make external-ingresses VM_IP=$VM_IP
```

The firewall rule `allow-kind-ingress` (TCP/8443) is now Terraform-managed (DD-39). It is created automatically by `make tf-apply`.

This produces five Ingress objects (Backstage, ArgoCD, Gitea, Grafana, plus the agent-housing-demo example) under `https://<svc>.<vm-ip>.sslip.io:8443/`.

The DD-26 `platform-config` ConfigMap (`base_domain: <vm-ip>.sslip.io`) drives the Backstage scaffolder's default `base_domain` so newly-scaffolded agents get the right host without operator typing. Update it whenever the VM IP changes:

```bash
kubectl create configmap platform-config -n whisperops-system \
  --from-literal=base_domain=$VM_IP.sslip.io \
  --from-literal=registry_url=$(terraform -chdir=terraform output -raw registry_url) \
  --dry-run=client -o yaml | kubectl apply -f -
```

### Stage 8 — Artifact Registry pull secret (DD-14)

Chicken-and-egg note: `ar-pull-secret` is created **per agent namespace**, so it can only be created after at least one `agent-*` namespace exists (i.e. after the first Backstage scaffold). On the very first deploy: scaffold one agent (Stage 9), let the pods land in `ImagePullBackOff`, then run:

```bash
make ar-pull-secret PROJECT_ID=<your-project-id>
kubectl rollout restart deploy/sandbox -n agent-<name>
kubectl rollout restart deploy/chat-frontend -n agent-<name>
```

The token from `gcloud auth print-access-token` expires every ~60 minutes — re-run `make ar-pull-secret` whenever pulls start failing 401.

### Stage 9 — first agent (Backstage)

See §2 below. After scaffolding, return to Stage 8 to refresh the pull secret if pods land in `ImagePullBackOff`.

### Smoke tests

`tests/smoke/` contains three scripts. Each accepts `IN_CLUSTER=1` for kubectl-port-forward mode (the practical default for a single-VM prototype where you don't always have firewall rules in place). Without `IN_CLUSTER=1` they hit the external sslip.io URLs.

```bash
# From the VM, with KUBECONFIG=/root/.kube/config
IN_CLUSTER=1 bash tests/smoke/platform-up.sh
IN_CLUSTER=1 bash tests/smoke/agent-creation.sh
IN_CLUSTER=1 bash tests/smoke/query-roundtrip.sh
```

The `query-roundtrip.sh` script asks the agent a numerical question and asserts the response contains a price-related answer + a code block. `IN_CLUSTER=1` mode is currently only fully implemented for `query-roundtrip.sh` (the other two are external-only — see DESIGN §15 open item #2).

### Known problems

| Symptom | Cause | Remedy |
|---|---|---|
| Anthropic API returns `overloaded_error` mid-query | Transient Anthropic capacity issue | Retry. No code change. |
| kagent autogen `sqlite UNIQUE constraint failed` after deleting and recreating an Agent CR | autogen v0.4.3 stores session state in an emptyDir-backed sqlite that doesn't reconcile with kagent's CR lifecycle | `kubectl rollout restart deploy/kagent -n kagent-system` (the emptyDir clears) |
| `chat-frontend` pod `ImagePullBackOff` ~60 min after deploy | AR pull-secret token expired | `make ar-pull-secret PROJECT_ID=<id>` |
| All sslip.io URLs unreachable after `terraform destroy && terraform apply` | VM external IP changed | Re-run Stage 7: `make external-ingresses VM_IP=<new-ip>` + recreate the `platform-config` ConfigMap. After a full destroy+apply there are no agents to re-scaffold (cluster was wiped); the regular bring-up handles everything from scratch. |
| OTel collector logs `at least 2 live replicas required, could only find 0` | lgtm-distributed Tempo distributor enforces min-2-ingester even with `replication_factor: 1` (single-node infeasible) | DD-30: `tempo.enabled: false` in `platform/observability/lgtm-values.yaml`; tempo-mono is sole backend |
| kagent emits zero spans even with `otel.tracing.enabled: true` | Chart hardcodes `AUTOGEN_DISABLE_RUNTIME_TRACING=true` (DD-22); override silently dropped if helmfile postRender script (DD-31) can't find `yq` on PATH | Install `yq` on the apply host; verify with `kubectl get deploy kagent -n kagent-system -o yaml \| grep -c AUTOGEN_DISABLE_RUNTIME_TRACING` (must be 1, value `false`) |
| `sops --decrypt` fails with "Error getting data key: 0 successful groups required, got 0" on a fresh laptop | Local clock skewed; SOPS refuses with no helpful message | `sudo systemctl status systemd-timesyncd` (Linux) / `sntp -sS time.apple.com` (macOS). Resync, retry. |
| Crossplane ProviderConfig `error unmarshaling credentials: invalid character '\n' in string literal` | SOPS-decrypted JSON has real newlines inside `private_key` | Repair pass — see `docs/NEXT_STEPS.md §0.6` |
| `kubectl get apps -A` shows `agent-X` Healthy but agent chat returns 503 | Budget-controller (DD-28) detected spend ≥ budget; Kyverno blocked sessions | Increase budget annotation `whisperops.io/budget-usd` on the namespace, or wait for the next billing window |

### Teardown (DD-32)

The reverse of bring-up has a strict ordering. Skipping or reordering steps leaves orphaned GCP resources outside both tfstate and any controller's reach.

**Canonical order** (executed by `make destroy`):

1. **Drain Crossplane Managed Resources.** Per-agent buckets, service accounts, and IAM bindings created by Backstage scaffolds are owned by Crossplane (`*.gcp.upbound.io`), not Terraform. Deleting Terraform first removes the bootstrap SA's IAM permissions, after which Crossplane finalizers can never complete and the GCP resources become orphaned. `make drain-crossplane` issues `kubectl delete --all` for every Crossplane GCP CRD and waits up to 5 min for finalizers.
2. **Empty Crossplane-owned GCS buckets.** The Terraform-managed datasets bucket has `force_destroy = true` (demo-only; the destruction is gated by the confirmation prompt in step 1). Per-agent artifact buckets, however, are created by Crossplane Bucket CRs scaffolded by Backstage and may not all set the equivalent `forceDestroy` flag. `make empty-buckets PROJECT_ID=<id>` empties any bucket labelled `managed_by=crossplane`. The tfstate bucket (`<project>-tfstate`) is intentionally NOT touched — preserve it until you are sure the destroy succeeded.
3. **Run `terraform destroy`.** With Crossplane drained and buckets empty, Terraform tears down the VM, VPC, static IP, bootstrap SA, datasets bucket, and Artifact Registry repo without errors.

```bash
make destroy                    # interactive: asks you to type the project id to confirm
make destroy FORCE=1            # CI/scripted: skip the confirmation prompt
make destroy SKIP_CROSSPLANE=1  # cluster already gone (kubectl unreachable)
make destroy SKIP_BUCKETS=1     # buckets known to be empty
```

The targets `drain-crossplane` and `empty-buckets PROJECT_ID=<id>` can also run standalone if you want to clean up partial state without tearing down Terraform.

**What `destroy` does not touch:**

- `<project>-tfstate` GCS bucket (operator must remove manually after verifying destroy succeeded).
- Gitea repos for agents (they live inside the kind cluster, gone with the VM).
- Langfuse Cloud / Supabase / Anthropic / OpenAI accounts (external SaaS).
- Local `secrets/*.dec.yaml`, `terraform.tfstate` cache, age key.

---

## §2 — Backstage deploy + agent interaction

### Caminho A — SSH tunnel + CNOE path-routing (DD-38, current default)

The pre-built CNOE Backstage image hardcodes Keycloak SignInPage in its frontend bundle and ships without a guest provider plugin in the backend. DD-33's app-config-only guest auth attempt didn't work; DD-38 reverted to Keycloak OIDC and adopted SSH-tunnel access as the operational path. Custom-image rebuild is deferred to v0.4 (DESIGN §15 #22, bundled with #17 sslip→DNS).

**Open the tunnel** (terminal 1, keep alive while testing):

```bash
gcloud compute ssh whisperops-vm --zone=us-central1-a -- -L 8443:127.0.0.1:8443
```

**Surfaces requiring the tunnel** (Keycloak OIDC dependent):

| Surface | URL (via tunnel) | Login |
|---|---|---|
| Backstage | `https://cnoe.localtest.me:8443/` | Keycloak `user1`/`user2` (realm `cnoe`) |
| ArgoCD | `https://cnoe.localtest.me:8443/argocd` | `admin` + initial-admin-secret |
| Gitea | `https://cnoe.localtest.me:8443/gitea` | `giteaAdmin` + gitea-credential Secret |
| Keycloak admin | `https://cnoe.localtest.me:8443/keycloak/admin/master/console/` | `admin` + KEYCLOAK_ADMIN_PASSWORD |

**Surfaces NOT requiring the tunnel** (no Keycloak realm dependency; sslip.io external):

| Surface | URL (direct) | Login |
|---|---|---|
| Grafana | `https://grafana.<vm-ip>.sslip.io:8443/` | `admin` + `lgtm-distributed-grafana` Secret |
| Per-agent chat-frontend | `https://agent-<name>.<vm-ip>.sslip.io:8443/` | none |

**Retrieving Keycloak realm credentials**:

```bash
kubectl get secret -n keycloak keycloak-config -o jsonpath='{.data.USER_PASSWORD}' | base64 -d
# user1 / user2 share this password
```

**Pre-requisite**: `dig +short cnoe.localtest.me` must return `127.0.0.1`. The Makefile preflight enforces this since DD-38 (was Optional under DD-33).

**Future cutover (Opção L)**: rebuild custom Backstage image with `@backstage/plugin-auth-backend-module-guest-provider` + `<SignInPage providers={['guest']} />` in App.tsx. Eliminates tunnel for Backstage UI access. Tracked as §15 #22.

### Templates sourcing (DD-40)

Backstage's catalog reads from a single Gitea repo: `idpbuilder-localdev-backstage-templates-entities` at `https://cnoe.localtest.me:8443/gitea/giteaAdmin/...`. The whisperops `dataset-whisperer` template lives at `platform/idp/backstage-templates/entities/dataset-whisperer/` in this repo, and is automatically synced to Gitea by `make _vm-bootstrap` (DD-34) — the sync step clones the Gitea repo, rsyncs `entities/`, commits, and pushes.

**Adding new templates**: drop a new `template.yaml` under `platform/idp/backstage-templates/entities/<name>/`, update `entities/catalog-info.yaml` to register a Location, and re-run `make copy-repo && make deploy-vm`. Backstage detects the new template within ~60 seconds.

**Manual force-sync** (if catalog refresh is slow or you skipped `_vm-bootstrap`): see the equivalent shell block in the `_vm-bootstrap` target of the Makefile.

**Backstage refresh trigger** (force immediate reload):
```bash
sudo kubectl --kubeconfig=/root/.kube/config rollout restart deployment/backstage -n backstage
```

After scaffolding via the Backstage UI (`Create` -> choose `dataset-whisperer`), Backstage pushes a new Gitea repo for the agent and creates an ArgoCD Application that syncs the agent's manifests.

### Accessing Backstage

```
https://backstage.<vm-ip>.sslip.io:8443/
```

(login fails — use Caminho A above)

The first time you load this URL via the tunnel (`https://cnoe.localtest.me:8443/`), browsers will warn about the cert. Proceed anyway — this is a prototype.

Login uses Keycloak OIDC (DD-38 — DD-33 guest auth attempt reverted). Use the SSH tunnel (Caminho A above) and sign in with Keycloak `user1` or `user2` credentials from the `keycloak-config` Secret.

### Filling the form

Click **Create** → choose **Dataset Whisperer** template → click **Choose**. Fields:

| Field | Type | Notes |
|---|---|---|
| `agent_name` | string (slug, lowercase, hyphenated) | Becomes the namespace `agent-<name>`, GCS bucket `agent-<name>`, GCP SA `agent-<name>@…`, and Gitea repo path. No suffix is appended (DD-13). |
| `description` | string | Free-form, displayed on the agent's chat page header. |
| `base_domain` | string | Defaults from the `platform-config` ConfigMap (DD-26). Must include the VM IP — e.g. `136.115.224.138.sslip.io`. Plain `sslip.io` resolves to nothing. |
| `dataset_id` | enum | `california-housing`, `online-retail-ii`, `spotify-tracks`. Mounts the matching CSV into the agent's sandbox at startup. |
| `primary_model` | enum | `claude-sonnet-4-5-20250929` is the v0.3 default for both `model-primary` and `model-planner` (DD-16; Haiku 4.5 is not classified as function-calling-capable by autogen v0.4.3, so the planner cannot use it). |
| `budget_usd` | number | Annotation `whisperops.io/budget-usd`; budget-controller (DD-28) writes `whisperops.io/spend-usd` every 60s; Kyverno blocks new sessions when spend ≥ budget. |

Submit. The scaffolder creates a Gitea repo at `gitea/whisperops/agent-<name>` and an ArgoCD `Application` pointing at it.

### What happens after submit

Roughly 60–90 seconds end-to-end on a warm cluster:

1. Gitea repo created with the rendered skeleton (Crossplane CRDs, kagent ModelConfigs and Agents, ToolServer, Sandbox Deployment, chat-frontend Deployment, Ingress, Kyverno NetworkPolicy)
2. ArgoCD syncs the Application → namespace `agent-<name>` is created
3. Crossplane reconciles the four GCP resources: `Bucket`, `ServiceAccount`, `ServiceAccountKey`, two `ProjectIAMMember` (one for the agent's own bucket, one for read on the shared datasets bucket). The SA key Secret materializes via `writeConnectionSecretToRef` directly in the agent's namespace
4. kagent reconciles the three Agents (planner, analyst, writer) → all reach `Accepted=True`
5. Sandbox + chat-frontend pods come up. If they `ImagePullBackOff`, run `make ar-pull-secret PROJECT_ID=<id>`
6. Per-agent Ingress is reachable at `https://agent-<name>.<vm-ip>.sslip.io:8443/`

### Chatting with the agent

Open the per-agent URL. Type a question. The chat-frontend route `app/api/chat/route.ts` does (1) `GET /api/agents/<ns>/<name>` to identify the planner, (2) `POST /api/sessions` (sticky-cookied per browser) to create or reuse a session, (3) `POST /api/sessions/<id>/invoke` with the user message, and (4) translates kagent's SSE stream into the browser-side SSE shape.

Three example questions for the `california-housing` dataset:

| Type | Prompt | Expected response shape |
|---|---|---|
| Numerical | "What is the median house price in this dataset?" | One-paragraph factual answer with the dollar value, plus a Python code block showing the `df['median_house_value'].median()` call |
| Chart | "Plot the distribution of median income." | Markdown reply with an embedded chart URL (signed GCS URL into the per-agent bucket) plus the matplotlib code |
| Code-style | "Show me the top 5 districts by population." | Tabular markdown rendering of a 5-row DataFrame, plus the `nlargest` code block |

The planner runs Sonnet 4.5 (DD-16). The analyst calls `execute_python(code)` on the per-agent sandbox MCP server (`http://sandbox.agent-<name>.svc.cluster.local:8080/mcp/` — note trailing slash, the MCP server 307-redirects from bare `/mcp`). The writer composes the final markdown.

The end-to-end "what is the median price?" smoke test takes ~6–10s on a warm cluster, ~30s cold.

### Tearing down an agent

```bash
kubectl delete application agent-<name> -n argocd --cascade=foreground
# Crossplane reconciles deletion of the GCS bucket + GCP SA + key + IAM bindings
# Allow ~60s for full cloud cleanup. Confirm:
gcloud iam service-accounts list --filter="email:agent-<name>@*"
gcloud storage buckets list --filter="name:agent-<name>"
# Both should be empty.
```

If you want to recreate the same agent with the same name, also delete the Gitea repo via API (`DELETE /api/v1/repos/whisperops/agent-<name>`) so the next Backstage scaffold doesn't fail with "repo exists".

---

## §3 — Observability navigation

Three datasources, one Grafana, one external SaaS. Grafana is at `https://grafana.<vm-ip>.sslip.io:8443/` (admin password: `kubectl get secret -n observability lgtm-distributed-grafana -o jsonpath='{.data.admin-password}' | base64 -d`).

### Grafana dashboards (provisioned via sidecar)

The Grafana sidecar auto-loads any ConfigMap labelled `grafana_dashboard: "1"` in the `observability` namespace. Four dashboards land under the **whisperops** folder:

| Dashboard | Datasource(s) | Key panels |
|---|---|---|
| **platform-health** | Mimir (`prom`), Loki (`loki`) | Cluster CPU/memory, ArgoCD synced/healthy app count, NGINX p50/p95/p99 latency, cert-manager expiries |
| **agent-cost** | Infinity (`langfuse`) primary, Tempo (`tempo`) fallback | Total spend per agent (Langfuse REST), per-model token rollup, top-10 agents by cost, daily burn |
| **agent-performance** | Tempo (`tempo`), Mimir (`prom`) | Query latency p50/p95/p99, A2A hop breakdown (planner→analyst→writer), error rate by error class |
| **sandbox-execution** | Tempo (`tempo`), Mimir (`prom`) | Concurrent executions, OOM rate, timeout rate, signed-URL upload latency |

### Tempo (TraceQL) — `tempo` datasource

Pointed at `tempo-mono.observability.svc.cluster.local:3100` per DD-21/DD-30. The lgtm-distributed Tempo sub-chart is disabled — `tempo-mono` is the sole backend.

Useful queries:

```traceql
# All spans from the kagent controller — sees Agent reconciliations
{ resource.service.name = "kagent" }

# Agent reconciliation events specifically
{ name =~ "create_agent.*" }

# Chat sessions (one trace per user turn)
{ name = "chat" }

# autogen LLM calls — cost lives here
{ span.gen_ai.system = "autogen" }
# Drill into a span for `gen_ai.usage.totalCost`, `gen_ai.usage.input_tokens`, `gen_ai.usage.output_tokens`

# A2A messages from planner to analyst
{ span.messaging.destination = "analyst" }

# Per-agent narrowing (k8sattributes processor adds these)
{ resource.k8s.namespace.name = "agent-housing-demo" }
```

OTel collector pipeline (per DD-24/v1.6):

```
autogen runtime → OTel SDK → opentelemetry-collector
   ├── otlp/tempo       → tempo-mono              (TraceQL)
   └── otlphttp/langfuse → Langfuse Cloud (US)    (LLM-ops UX)
```

### Loki — `loki` datasource

Pod logs. Useful filters:

```logql
# Sandbox logs — Python execution stdout/stderr
{namespace=~"agent-.+", app="sandbox"}

# Chat-frontend Next.js logs — pino JSON
{namespace=~"agent-.+", app="chat-frontend"} | json

# kagent controller events
{namespace="kagent-system"} |= "reconcile"

# Budget-controller poll loop
{namespace="whisperops-system", app="budget-controller"}
```

### Mimir/Prometheus — `prom` datasource

`whisperops_*` metrics emitted by the budget-controller (DD-28) and `sandbox_*` metrics from the per-agent sandbox `/metrics` endpoint:

```promql
# Per-agent current spend (60s polling)
whisperops_agent_spend_usd{agent="agent-housing-demo"}

# Budget-burn alert source — counts of 80% / 100% events
whisperops_budget_80pct_total
whisperops_budget_100pct_total

# Sandbox internals
sandbox_executions_total
sandbox_oom_total
sandbox_timeout_total
rate(sandbox_execution_duration_seconds_sum[5m]) / rate(sandbox_execution_duration_seconds_count[5m])
```

### Langfuse Cloud — external UI

```
https://us.cloud.langfuse.com/
```

Login with the project credentials embedded in `secrets/langfuse.enc.yaml`. Same trace data as Tempo, but with LLM-ops UX:

- **Per-agent cost rollup** — projects + sessions filterable by `metadata.agent.id`
- **Prompt + response visible in browser** — clickable, syntax-highlighted, with token counts
- **Score annotation** — manual or evaluator-driven scoring on individual generations
- **Dataset eval** — replay a saved input set against a new prompt version

Direct deeplink for a single trace (when you have a trace ID from Tempo):

```
https://us.cloud.langfuse.com/project/<projectId>/traces/<traceId>
```

The `<projectId>` is fixed per Langfuse project; `<traceId>` is the same UUID you see as `trace_id` in Tempo (single OTel TraceContext propagated through both backends). Open a Tempo trace, copy the trace ID, paste into the Langfuse URL — same data, two perspectives.

### Grafana Infinity datasource (`langfuse`) — Langfuse REST from Grafana

Provisioned by `platform/observability/grafana-langfuse-datasource.yaml` (DD-24, v1.6). Lets you build Grafana panels off Langfuse REST endpoints using `${LANGFUSE_BASIC_AUTH}` env-var substitution.

Example panel — top 10 traces by cost:

```
URL:    ${LANGFUSE_HOST}/api/public/traces?limit=10&orderBy=cost
Format: JSON
Root:   data
Columns: id, name, totalCost, latency, userId
```

The same data is what the budget-controller polls every 60s on the `langfuse` poll target.

### Budget-controller flow (DD-28)

1. Every 60s, the controller calls `GET ${LANGFUSE_HOST}/api/public/observations?fromTimestamp=<window>` (or `Mimir whisperops_agent_spend_usd` if `pollTarget: mimir`)
2. Aggregates `usage.totalCost` per agent (`metadata.agent.id` tag)
3. Patches the Kubernetes annotation `whisperops.io/spend-usd` on each `agent-*` namespace
4. Emits Prometheus metrics: `whisperops_agent_spend_usd`, `whisperops_budget_80pct_total`, `whisperops_budget_100pct_total`
5. Kyverno `ClusterPolicy` (audit mode in v0.3, enforce in v0.4) blocks new chat sessions when `spend-usd >= budget-usd`

To inspect:

```bash
kubectl get ns agent-housing-demo -o jsonpath='{.metadata.annotations}'
kubectl logs -n whisperops-system deploy/budget-controller -f
```

---

## Cross-references

- DESIGN decisions (DD-1 through DD-36) — `.claude/sdd/features/DESIGN_whisperops.md` (gitignored, internal)
- Acceptance tests — `.claude/sdd/features/DEFINE_whisperops.md` (gitignored, internal)
- Architecture deep-dive — `docs/ARCHITECTURE.md`
- Security model — `docs/SECURITY.md`
- Open items + future phases — DESIGN §15 + `docs/NEXT_STEPS.md`
- Smoke tests — `tests/smoke/{platform-up,agent-creation,query-roundtrip}.sh`
