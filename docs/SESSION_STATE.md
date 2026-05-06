# Session State — 2026-05-06 (late evening update)

Live state of the whisperops deploy after the 2026-05-06 sessions (platform-bring-up + Phase 2 sandbox MCP + Phase 3 demo-routing). Supersedes the earlier 2026-05-06 version of this file.

> **One-paragraph TL;DR.** The platform layer is fully deployed, the per-agent stack provisions real GCP resources end-to-end, the **sandbox MCP server is built, sideloaded, and live** in the cluster, and kagent's ToolServer **discovered the `execute_python` tool**. The **`analyst` Agent is now `Accepted=True`** (along with planner + writer). The per-agent chat URL routes to kagent's built-in UI via an ExternalName Service. Smoke-test for first end-to-end query is a browser interaction at this point, not more infra.

---

## What's deployed (and working)

### Cloud floor — GCP project `whisperops`

| Resource | State |
|---|---|
| GCS bucket `whisperops-tfstate` | ✓ |
| GCS bucket `whisperops-datasets` | ✓ Populated with 3 CSVs |
| GCS bucket `agent-housing-demo` | ✓ **Created today by Crossplane via Backstage scaffolder** |
| VPC `whisperops-vpc` + subnet | ✓ |
| GCE VM `whisperops-vm` (e2-standard-8, ubuntu-2204-lts) | ✓ |
| Static external IP `136.115.224.138` | ✓ |
| Bootstrap SA `whisperops-bootstrap@whisperops.iam.gserviceaccount.com` | ✓ Re-bound today: `iam.serviceAccountAdmin`, `iam.serviceAccountKeyAdmin`, `resourcemanager.projectIamAdmin`, `storage.admin` — all **unconditional** (see "IAM model correction" below) |
| GCP service account `agent-housing-demo@whisperops...` | ✓ **Created today by Crossplane** |
| Service account key (live in GCP IAM) | ✓ **Minted today** — connection-secret materialized as `gcp-sa-key` Secret in agent-housing-demo namespace |
| ProjectIAMMembers (object-admin on agent bucket; object-viewer on shared datasets) | ✓ |

### IDP layer (idpbuilder, on the VM)

Same as 2026-05-05 — all CNOE ref-implementation apps Synced/Healthy:

| Component | State |
|---|---|
| kind cluster `localdev` | ✓ |
| ArgoCD, Gitea, Backstage, Keycloak | ✓ |
| ESO, argo-workflows, metric-server, nginx, spark-operator | ✓ |

### Application platform layer (helmfile, **new today**)

Deployed via `helmfile -f platform/helmfile.yaml.gotmpl sync` on the VM:

| Helm release | Namespace | Version | State |
|---|---|---|---|
| crossplane | crossplane-system | 1.17.1 | ✓ Healthy |
| kagent-crds | kagent-system | 0.4.3 | ✓ |
| kagent | kagent-system | 0.4.3 | ✓ Healthy (5/5 containers after `kagent-openai` Secret created) |
| kyverno | kyverno | 3.2.6 | ✓ |
| lgtm-distributed | observability | 2.1.0 | ✓ |
| opentelemetry-collector | observability | 0.104.0 | ✓ |

### Crossplane providers (**new today**)

Three sub-providers from the Upbound family pattern (the monolithic `provider-gcp` that DESIGN named was retired from xpkg.upbound.io):

| Provider | Version | State |
|---|---|---|
| upbound/provider-gcp-storage | v1.9.4 | ✓ Healthy |
| upbound/provider-gcp-iam | v1.9.4 | ✓ Healthy |
| upbound/provider-gcp-cloudplatform | v1.9.4 | ✓ Healthy |
| upbound/provider-family-gcp | (auto, dependency) | ✓ Healthy |

### Per-agent stack: `agent-housing-demo` (**new today**)

ArgoCD app `agent-housing-demo` is **Healthy**. All resources in the namespace:

| Kind | Name | State |
|---|---|---|
| Namespace | agent-housing-demo | ✓ |
| ServiceAccount (Crossplane) | agent-housing-demo | ✓ Synced/Ready in GCP |
| ServiceAccountKey (Crossplane) | agent-housing-demo-key | ✓ Synced/Ready (real key in IAM, secret materialized) |
| Bucket (Crossplane) | agent-housing-demo | ✓ Synced/Ready (real GCS bucket) |
| ProjectIAMMember × 2 | bucket-admin, datasets-viewer | ✓ Synced/Ready |
| ModelConfig (kagent) | model-primary, model-planner | ✓ |
| Agent (kagent) | planner | ✓ Accepted=True |
| Agent (kagent) | writer | ✓ Accepted=True |
| Agent (kagent) | analyst | ✓ **Accepted=True** (was False; sandbox MCP server now live) |
| ToolServer (kagent) | sandbox | ✓ **Accepted=True**, `execute_python` in `discoveredTools` |
| Policy (kyverno) | agent-egress-policy | ✓ Ready=True |
| Service (ExternalName) | chat-frontend-housing-demo → kagent.kagent-system | ✓ Routes browser traffic at the kagent UI |
| Ingress | agent-housing-demo (host `agent-housing-demo.sslip.io`) | ✓ |

### Sandbox (**new today, separate from per-agent stack**)

| Kind | Name | State |
|---|---|---|
| Namespace | sandbox | ✓ |
| Helm release | sandbox 0.1.0 | ✓ deployed |
| Deployment | sandbox (image `whisperops/sandbox:0.1.3`, sideloaded) | ✓ 1/1 Ready |
| Service | sandbox:8080 | ✓ |
| NetworkPolicy | sandbox-network-policy (ingress from kagent-system only) | ✓ |
| MCP endpoint | `http://sandbox.sandbox.svc.cluster.local:8080/mcp` | ✓ Tools discovered by kagent |

---

## What's working end-to-end (closed today)

### 1. Sandbox MCP server (Phase 2 — **DONE**)

`src/sandbox/app/mcp_server.py` wraps the existing FastAPI sandbox in an MCP layer using the official `mcp==1.27.0` Python SDK. Tool surface deliberately minimized to `execute_python(code: str) -> str` — pre-loads pandas + numpy + the california-housing CSV (baked into the image) as `df`. Mounted on the same uvicorn process at `/mcp`.

**Three subtle bugs fixed during this work** (all caught and committed):
- `mcp 1.27.0` requires `pydantic >= 2.11`; relaxed our pin from `==2.10.3` to `>=2.11.0,<3`.
- Starlette's `app.mount()` silently drops the inner ASGI app's lifespan, so the MCP `session_manager` task group never initialized → every `/mcp` request crashed with `RuntimeError: Task group is not initialized`. Wired the MCP session manager's `run()` into FastAPI's `lifespan` context.
- FastMCP's DNS rebinding protection rejected cluster-internal Host headers like `sandbox.sandbox.svc.cluster.local` (HTTP 421). Disabled the protection — NetworkPolicy already restricts ingress to `kagent-system`.

### 2. Per-agent chat URL → kagent built-in UI (Phase 3 — **simplified, DONE for demo**)

DESIGN intended a custom Next.js chat-frontend per agent. The skeleton's existing `src/chat-frontend/` calls a fictional `${PLANNER_URL}/v1/messages` endpoint that kagent does not expose. **Rather than build a new chat-frontend**, the per-agent skeleton now ships an `ExternalName` Service that aliases `chat-frontend-{agent_name}` to `kagent.kagent-system.svc.cluster.local`. The Ingress targets that Service at port 80.

Result: opening the per-agent URL lands the user in kagent's built-in chat UI, where they pick `agent-housing-demo/planner` from the dropdown and chat. Trade-off: the UI shows all agents in the cluster instead of being agent-scoped — acceptable for a first demo, replaced later by a purpose-built UI (NEXT_STEPS Phase 3.full).

### 3. Image pipeline (sideload-only, Phase 1 — **DONE for demo**)

The clean registry path (Gitea container registry + containerd mirror) is still future work. **For demo purposes**, the sandbox image is built on the VM with `docker build -f src/sandbox/Dockerfile -t whisperops/sandbox:0.1.3 .` and sideloaded into kind via `docker save | docker exec localdev-control-plane ctr -n=k8s.io images import -`. `kind load docker-image` v0.25 fails against this idpbuilder cluster with "failed to detect containerd snapshotter" — the manual `ctr import` path is the workaround.

This means **a fresh kind cluster will not have the sandbox image**; the build/sideload procedure must be re-run after any cluster recreate. Captured as a known-recurring bug; full registry path is NEXT_STEPS Phase 1.

---

## What's NOT working yet

### 1. End-to-end chat smoke test (browser-only at this point)

The agent runtime is verifiably wired: kagent reaches the sandbox, ToolServer discovery succeeds, Agents accept their tool refs. However the human "type a question, see an answer" loop hasn't been exercised this session — direct curl invocation of `/api/sessions/{id}/invoke` returns 422 from kagent's autogen app, which means the request body shape needs to match exactly what the kagent UI sends. Easiest test: **port-forward kagent UI and use the browser** (instructions below).

### 2. Per-agent UI scoping

Today, the kagent UI shows every agent in the cluster. The "operator scaffolds an agent → user gets a private chat at that URL" promise is partially delivered (the URL works) and partially not (the UI isn't agent-scoped). Phase 3.full in NEXT_STEPS.

### 3. Container registry

Image lives only in the kind node's containerd, sideloaded. Reproducible on a fresh cluster requires manual rebuild + sideload. Phase 1 in NEXT_STEPS.

---

## Smoke-test the chat (manual, browser)

```bash
# 1) Port-forward the kagent UI
gcloud compute ssh whisperops-vm --zone=us-central1-a -- -L 8888:localhost:8888 &
gcloud compute ssh whisperops-vm --zone=us-central1-a --command='
  sudo kubectl --kubeconfig=/root/.kube/config -n kagent-system port-forward --address=0.0.0.0 svc/kagent 8888:80
' &

# 2) In a browser: http://localhost:8888
# 3) Pick agent-housing-demo/planner from the dropdown
# 4) Ask: "What is the median house price in California?"
# 5) Watch kagent dispatch to planner → analyst (which calls sandbox.execute_python) → writer
# 6) Verify in `kubectl logs -n sandbox -l app.kubernetes.io/name=sandbox` that the MCP tool was invoked
```

---

## Bugs fixed today (committed; won't recur)

All in commit `0b91787` ("fix(platform,scaffolder): reconcile DESIGN-time templates with shipped CRD schemas") and live on `main`.

### Platform helmfile

| Bug | Fix |
|---|---|
| `charts.kagent.dev` doesn't resolve | Use `oci://ghcr.io/kagent-dev/kagent/helm/kagent` |
| kagent install fails: "ensure CRDs are installed first" | Install `kagent-crds` chart **first**, then `kagent` |
| kagent install fails: "namespace 'kagent' not found" | Pre-create the `kagent` namespace (the chart targets two namespaces: `kagent-system` and `kagent`) |
| OTel collector fails: "image.repository must be set" | v0.104.0+ requires explicit `mode: deployment` + `image.repository: otel/opentelemetry-collector-contrib` |
| `argocd-root-app` release collides with CNOE ArgoCD | Release dropped from helmfile |

### Crossplane

| Bug | Fix |
|---|---|
| `upbound/provider-gcp:v0.42.0` retired from xpkg | Switch to family pattern: `provider-gcp-storage` + `provider-gcp-iam` + `provider-gcp-cloudplatform` at v1.9.4 |
| ProviderConfig `projectID: ""` | Set to `whisperops` |
| Crossplane GCP credential Secret rejected: "invalid character '\\n' in string literal" | Decrypted SOPS YAML had real newlines inside the `private_key` JSON value. Repaired by parsing leniently and re-emitting with `\n` escapes (see `docs/runbooks/sops-gcp-creds-repair.md` if/when written; for now follow the procedure in NEXT_STEPS §0) |

### Backstage skeleton templates (all in `backstage-templates/dataset-whisperer/skeleton/`)

| Bug | Fix |
|---|---|
| Agent `apiVersion: kagent.dev/v1` rejected | Use `v1alpha1` (only version shipped through 0.7.9) |
| Agent `spec.model` rejected | Use `spec.modelConfig: <ref>` + new `ModelConfig` CR (added two: `modelconfig-primary.yaml.njk`, `modelconfig-planner.yaml.njk`) |
| Agent `spec.systemPromptConfigMapRef` rejected | Use inline `spec.systemMessage` |
| Agent `spec.tools[].name/toolServer/toolServerNamespace` rejected | Use `spec.tools[].type=McpServer` + `mcpServer.{toolServer, toolNames}` |
| Agent `spec.observability` rejected | Field doesn't exist in the CRD; per-agent OTel tagging deferred |
| ToolServer `spec.transport` rejected | Use `spec.config.streamableHttp.url` |
| ServiceAccountKey `serviceAccountRef` rejected | Use `serviceAccountIdRef` |
| Bucket creation: org policy `storage.uniformBucketLevelAccess` violation | Add `forProvider.uniformBucketLevelAccess: true` |
| ProjectIAMMember "for project ''" 403 | Add `forProvider.project: ${{ values.project_id }}` |
| Kyverno policy: "variable substitution failed: variable `null`" | Replaced nested-template `{{ \`{{request.object.metadata.name}}\` }}` with a `validate.pattern` form (no variables) |
| ExternalSecret references non-existent `cluster-secret-store` and Password generator | Manifest deleted entirely; the real key flow is `ServiceAccountKey.spec.writeConnectionSecretToRef` |

### IAM model correction

| Bug | Fix |
|---|---|
| Bootstrap SA conditional bindings always fail on `create` operations because `resource.name` is empty at create-time (a known GCP IAM Conditions limitation, not a typo) | Conditions removed from `roles/iam.serviceAccountAdmin` and `roles/iam.serviceAccountKeyAdmin`. Naming convention now enforced **only at the template level** (`metadata.name: agent-${{ values.agent_name }}`). |
| ProjectIAMMember reconcile fails with "permission denied retrieving IAM policy" | Added `roles/resourcemanager.projectIamAdmin` (no condition) to the bootstrap SA |
| `kagent` pod 4/5 with `CreateContainerConfigError` (querydoc sidecar) | Created `kagent-openai` Secret in `kagent-system` from SOPS-decrypted `secrets/openai.enc.yaml` |

### Skeleton + iam-bindings: project_id / values.X fully resolved

The Backstage scaffolder template now correctly substitutes `${{ values.project_id }}`, `${{ values.region | default('US-CENTRAL1') }}`, and `${{ values.base_domain | default('sslip.io') }}` in all rendered files (verified via local sed-render against the Gitea repo). No remaining placeholder leakage.

---

## Bugs NOT fixed (recurring on fresh deploy — operator must handle)

1. **CNOE Keycloak config-job idempotency** — same as 2026-05-05. If the job crashes between realm-creation and secret-creation, the next run sees the realm and exits 0 without creating the secret. Manual recovery: delete the keycloak namespace + force resync.

2. **kagent installation ordering** — the Helm chart fails on first install unless the `kagent` namespace pre-exists and the `kagent-crds` chart is installed first. Captured in NEXT_STEPS §0.4.

3. **SOPS-decrypted JSON key newline corruption** — the encrypted GCP credential file in `secrets/crossplane-gcp-creds.enc.yaml` decrypts to malformed JSON (real newlines inside the private_key string). The bootstrap procedure must include a Python-based repair pass before applying to Kubernetes. Captured in NEXT_STEPS §0.6.

4. **GCP IAM propagation delay** — bootstrapping the bootstrap SA's role bindings, then immediately running ArgoCD sync, results in 403s for ~60-90 seconds while IAM converges. Operator must wait or expect retries.

---

## Operator runbook one-liners

```bash
# SSH tunnel for browser access
gcloud compute ssh whisperops-vm --zone=us-central1-a -- -L 8443:localhost:8443

# Pull all credentials
gcloud compute ssh whisperops-vm --zone=us-central1-a --command='
  echo "=== ArgoCD ==="; sudo kubectl --kubeconfig=/root/.kube/config -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d; echo
  echo "=== Gitea token ==="; sudo kubectl --kubeconfig=/root/.kube/config -n gitea get secret gitea-credential -o jsonpath="{.data.token}" | base64 -d; echo
  echo "=== Keycloak admin ==="; sudo kubectl --kubeconfig=/root/.kube/config -n keycloak get secret keycloak-config -o jsonpath="{.data.KEYCLOAK_ADMIN_PASSWORD}" | base64 -d; echo
'

# All ArgoCD apps health
gcloud compute ssh whisperops-vm --zone=us-central1-a --command='sudo kubectl --kubeconfig=/root/.kube/config get apps -A'

# All Crossplane providers / managed resources
gcloud compute ssh whisperops-vm --zone=us-central1-a --command='sudo kubectl --kubeconfig=/root/.kube/config get providers.pkg.crossplane.io,managed -A'

# Force re-sync agent-housing-demo
gcloud compute ssh whisperops-vm --zone=us-central1-a --command='
  sudo kubectl --kubeconfig=/root/.kube/config -n argocd patch app agent-housing-demo \
    --type=merge -p "{\"operation\":{\"sync\":{}}}"
'

# Tear down all per-agent infra (when iterating)
gcloud compute ssh whisperops-vm --zone=us-central1-a --command='
  sudo kubectl --kubeconfig=/root/.kube/config -n argocd delete app agent-housing-demo --cascade=foreground
  # Then delete the Gitea repo via API and re-scaffold from Backstage
'

# Tear down everything (full destroy)
make destroy
```

---

## Where to look for what

| Question | Where to look |
|---|---|
| What's the next thing to build? | `docs/NEXT_STEPS.md` |
| Why does X fail / what was the root cause? | `.claude/sdd/features/DESIGN_whisperops.md` Reality Reconciliation Appendix |
| What does the user-facing behavior look like? | `.claude/sdd/features/DEFINE_whisperops.md` |
| What's the platform install order? | `docs/NEXT_STEPS.md` §0 (clean-room reproduce) |
| Where's the AGE key for SOPS? | `age.key` (gitignored, on the operator's workstation) |
