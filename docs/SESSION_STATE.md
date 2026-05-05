# Session State — 2026-05-05

Live state of the whisperops deploy, captured at end-of-session for clean continuation.

---

## What's deployed (and working)

### Cloud floor — GCP project `whisperops`

| Resource | State |
|---|---|
| GCS bucket `whisperops-tfstate` | ✓ Pre-created manually; Terraform backend uses it |
| GCS bucket `whisperops-datasets` | ✓ Created by Terraform; populated with 3 CSVs |
| VPC `whisperops-vpc` + subnet | ✓ |
| GCE VM `whisperops-vm` (e2-standard-8, ubuntu-2204-lts) | ✓ Running |
| Static external IP `136.115.224.138` | ✓ Attached to VM |
| Bootstrap SA `whisperops-bootstrap@whisperops.iam.gserviceaccount.com` | ✓ Created with scoped IAM (CEL conditions on agent-* prefixes) |
| Bootstrap SA key | ✓ Minted, SOPS-encrypted in `secrets/crossplane-gcp-creds.enc.yaml` |
| Org policy `iam.disableServiceAccountKeyCreation` | ⚠️ Disabled at project level (re-enable when migrating to Workload Identity) |

### IDP layer (running on the VM via idpbuilder)

| Component | State | URL (via SSH tunnel `gcloud compute ssh whisperops-vm --zone=us-central1-a -- -L 8443:localhost:8443`) |
|---|---|---|
| kind cluster `localdev` | ✓ Running | — |
| ArgoCD | ✓ Healthy | https://cnoe.localtest.me:8443/argocd |
| Gitea | ✓ Healthy | https://cnoe.localtest.me:8443/gitea |
| Backstage | ✓ Healthy | https://cnoe.localtest.me:8443/ |
| Keycloak | ✓ Healthy | https://cnoe.localtest.me:8443/keycloak |
| ESO (external-secrets) | ✓ Healthy | — |
| argo-workflows | ✓ Healthy | https://cnoe.localtest.me:8443/argo-workflows |
| metric-server | ✓ Healthy | — |
| spark-operator | ✓ Running (unused — bundled by ref-implementation) | — |

### Backstage scaffolder

| Step | State |
|---|---|
| Dataset Whisperer template registered | ✓ |
| Form fields working | ✓ (manually tested with `housing-demo`) |
| `fetch:template` rendering | ✓ (after `${{...}}` syntax fix) |
| `publish:gitea` | ✓ Creates per-agent Gitea repo |
| `cnoe:create-argocd-app` | ✓ Wired; not exercised in this session |

### Per-agent state (housing-demo)

- Gitea repo `giteaAdmin/agent-housing-demo` exists with 15 rendered manifests
- ArgoCD `Application/agent-housing-demo` exists, **OutOfSync** because cluster lacks platform-layer CRDs

---

## What's blocking the demo

**The application platform layer is not deployed.** The Backstage scaffolder generates manifests that reference CRDs the cluster doesn't have:

| CRD missing | Owned by | Helm chart we have |
|---|---|---|
| `kagent.dev/Agent` | kagent operator | DESIGN §4.5 expected ArgoCD App `kagent` |
| `cloudplatform.gcp.upbound.io/*`, `storage.gcp.upbound.io/Bucket`, `iam.gcp.upbound.io/*` | Crossplane provider-gcp | DESIGN §4.6 has provider config but provider not installed |
| `kyverno.io/Policy` | Kyverno | `platform/helm/kyverno-policies/` exists but not deployed |

The CNOE ref-implementation gave us the IDP layer. Our DESIGN §4.5 platform Helm charts (sandbox, chat-frontend, kyverno-policies, observability-extras, agent-prompts, budget-controller, platform-bootstrap-job) and the upstream charts they depend on (kagent, Crossplane, Kyverno) need to be deployed before any agent can actually run.

---

## Exact next steps (next session)

### Step 1 — Install the missing operators

Three options, in order of correctness:

**Option A — Use our `platform/helmfile.yaml.gotmpl`** (the DESIGN intent)

```bash
gcloud compute ssh whisperops-vm --zone=us-central1-a
# (on VM)
sudo apt-get install -y helm helmfile  # or pull binaries directly
git clone https://github.com/zanonicode/whisperops /tmp/whisperops
cd /tmp/whisperops
sudo helmfile -f platform/helmfile.yaml.gotmpl --kubeconfig /root/.kube/config sync
```

This brings up: kagent + Crossplane + Crossplane provider-gcp + Kyverno + LGTM + OTel Collector + ArgoCD root-app pointing at `platform/argocd/applications/`. Each may surface its own bootstrap quirks (similar in flavor to today's Keycloak config-job debug); budget ~1–2 hr.

**Option B — Add the missing operators as idpbuilder packages**

Drop our `platform/argocd/applications/*.yaml` into a new `platform/idp-extras/` directory and re-run `idpbuilder create -p ...` against it. Cleaner than a separate helmfile but requires that the upstream charts work as ArgoCD Applications in the CNOE pattern.

**Option C — Install only the bare minimum to deploy `chat-frontend`**

The chat-frontend manifest in the agent's Gitea repo is plain Kubernetes (Deployment + Service + Ingress) — no CRDs needed. Tell ArgoCD to ignore the rest temporarily. Demo shows "scaffold an agent → see a chat UI come up" without the LLM actually working. Useful as a visual checkpoint but no real demo value beyond that.

### Step 2 — Re-sync the agent ArgoCD app

Once CRDs are present:

```bash
sudo kubectl --kubeconfig=/root/.kube/config -n argocd patch application agent-housing-demo \
  --type=merge -p '{"operation":{"sync":{}}}'
```

Watch the namespace come up:

```bash
sudo kubectl --kubeconfig=/root/.kube/config get all -n agent-housing-demo --watch
```

### Step 3 — Wire SOPS-decrypted secrets into the cluster

Crossplane needs `crossplane-gcp-creds.enc.yaml` decrypted as a K8s Secret in `crossplane-system`. The DESIGN had `platform/crossplane/external-secret-bootstrap.yaml` for this — but ESO needs the SOPS-decrypted plaintext somewhere it can read. Two paths:

- Run `sops -d secrets/crossplane-gcp-creds.enc.yaml | kubectl apply -f -` once after cluster bring-up
- Or wire SOPS-into-ESO (more work)

For demo: manual decrypt + kubectl apply is fine.

### Step 4 — End-to-end test

1. Visit `https://agent-housing-demo.<vm-ip>.sslip.io` (chat UI)
2. Ask a question: *"What's the median house price in California by latitude?"*
3. Watch traces in Grafana → Tempo
4. Verify chart renders and is signed-URL'd from per-agent bucket

---

## Bugs fixed this session (committed; won't recur)

| Bug | Commit |
|---|---|
| Terraform orphan `state_bucket_name` variable | `849774e` |
| `tfstate_bucket` chicken-and-egg in storage module | `ed1e98e` |
| `access_config` on wrong VM submodule (no public IP) | `<sha>` |
| idpbuilder v0.9.0 (404) → v0.10.2 with tar.gz unpack | `<sha>` |
| idpbuilder package URL `//backstage` → `//ref-implementation` | `<sha>` |
| Missing `kubectl` install in startup script | `<sha>` |
| Phantom OTel version pins (1.28.4 → 1.28.2) | `<sha>` |
| Missing chat-frontend `app/layout.tsx`, `globals.css`, `postcss.config.mjs`, `public/` | `<sha>` |
| Next 15.0.3 → 15.5.15 (peer dep) | `<sha>` |
| Vendored CNOE ref-implementation; patched Keycloak config-job URL bug | `60f972b` |
| Wait gate in startup script (poll until all apps Synced/Healthy) | `60f972b` |
| `make preflight` target | `60f972b` |
| Backstage `${{values.X}}` syntax (was bare Nunjucks `{{...}}`) | `277ee41` |
| Scaffolder action mismatch (`generate-suffix` removed; CNOE `cnoe:create-argocd-app` used) | `99600e2` |

---

## Bugs NOT fixed (recurring on fresh deploy)

1. **Keycloak config-job retry idempotency** — even with our URL fix, if the script crashes between realm-creation and secret-creation, the next run sees the realm and exits 0 without creating the secret. Manual recovery: delete the keycloak namespace + force resync. Should patch the upstream check to verify both realm AND secret.

2. **ArgoCD sync ordering deadlocks** — ArgoCD sometimes creates Deployments before required ConfigMaps. Force-sync via `syncOptions=[Replace=true,Force=true]` recovers.

---

## Operator runbook one-liners

```bash
# SSH tunnel for browser access
gcloud compute ssh whisperops-vm --zone=us-central1-a -- -L 8443:localhost:8443

# Pull all credentials at once
gcloud compute ssh whisperops-vm --zone=us-central1-a --command='
  echo "=== ArgoCD ==="; sudo kubectl --kubeconfig=/root/.kube/config -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d; echo
  echo "=== Gitea ==="; sudo /usr/local/bin/idpbuilder get secrets -p gitea | grep -A 1 PASSWORD
  echo "=== Keycloak admin ==="; sudo kubectl --kubeconfig=/root/.kube/config -n keycloak get secret keycloak-config -o jsonpath="{.data.KEYCLOAK_ADMIN_PASSWORD}" | base64 -d; echo
  echo "=== Keycloak user1 ==="; sudo kubectl --kubeconfig=/root/.kube/config -n keycloak get secret keycloak-config -o jsonpath="{.data.USER_PASSWORD}" | base64 -d; echo
'

# All ArgoCD apps health
gcloud compute ssh whisperops-vm --zone=us-central1-a --command='sudo kubectl --kubeconfig=/root/.kube/config get apps -A'

# Tear down (when done with demo)
make destroy
```
