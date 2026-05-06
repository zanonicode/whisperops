> **Current open items live in `.claude/sdd/features/DESIGN_whisperops.md` §15** (DESIGN v1.7, post-live-deploy). Most phases below are now closed (Phase 0–4 resolved per DESIGN Reality Reconciliation Appendix §D).
> The content below is preserved for historical context as the original phased roadmap.

# Next Steps — Path to a Fully Working Dataset Whisperer

> Roadmap from current state (platform layer up, agent CRs scaffolded, no agent runtime behavior yet) to the **fully working product as scoped in `.claude/sdd/features/DEFINE_whisperops.md`**: an operator fills a 4-field Backstage form, gets a per-agent chat UI in ~5 minutes, asks "What's the median house price in California by latitude?", and gets a real numerical answer with a chart link, all observable in Grafana and Langfuse, with budget enforcement and policy guardrails active.

This is sequenced for **shippability**, not for purity. Each section ends with an explicit acceptance check.

---

## Phase 0 — Clean-room reproduce (½ day)

**Why this is here:** before adding new code, prove the current state can be re-stood-up from scratch on a fresh GCP project. Everything below assumes this works.

### 0.1 — Tear down completely
```bash
make destroy   # Terraform destroy (GCS, VM, IAM)
```

### 0.2 — Bring up cloud floor + IDP
```bash
make plan && make apply        # cloud floor
# Wait for VM startup-script to finish (~6-8 min)
gcloud compute ssh whisperops-vm --zone=us-central1-a -- 'sudo kubectl --kubeconfig=/root/.kube/config get apps -n argocd'
# Expect: argocd, backstage, backstage-templates, gitea, keycloak, etc., all Synced/Healthy
```

### 0.3 — Mint bootstrap SA key + SOPS-encrypt
The org policy `iam.disableServiceAccountKeyCreation` must be temporarily disabled.

```bash
gcloud iam service-accounts keys create /tmp/key.json \
  --iam-account=whisperops-bootstrap@whisperops.iam.gserviceaccount.com
# Then SOPS-encrypt under secrets/crossplane-gcp-creds.enc.yaml using the AGE key
```

### 0.4 — Install application platform layer **in this order**
On the VM:
```bash
# Install helm + helmfile
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | sudo bash
curl -fsSL https://github.com/helmfile/helmfile/releases/download/v0.169.2/helmfile_0.169.2_linux_amd64.tar.gz | sudo tar -xz -C /usr/local/bin helmfile

# Pre-create kagent namespace (the chart hardcodes some resources here)
sudo kubectl --kubeconfig=/root/.kube/config create namespace kagent

# Install kagent CRDs FIRST (chart layout requires this)
sudo KUBECONFIG=/root/.kube/config helm upgrade --install kagent-crds \
  oci://ghcr.io/kagent-dev/kagent/helm/kagent-crds --version 0.4.3 \
  --create-namespace --namespace kagent-system

# Then helmfile sync the rest
git clone https://github.com/zanonicode/whisperops /tmp/whisperops
sudo KUBECONFIG=/root/.kube/config helmfile -f /tmp/whisperops/platform/helmfile.yaml.gotmpl sync
```

### 0.5 — Install Crossplane GCP family providers
On the VM:
```bash
sudo kubectl --kubeconfig=/root/.kube/config apply -f /tmp/whisperops/platform/crossplane/provider-gcp.yaml
# Wait for all 4 providers Healthy=True (provider-gcp-storage, provider-gcp-iam, provider-gcp-cloudplatform, upbound-provider-family-gcp)
```

### 0.6 — Bootstrap Crossplane GCP credentials (with newline-repair)
On the operator workstation:
```bash
SOPS_AGE_KEY_FILE=/Users/vitorzanoni/whisperops/age.key sops -d --extract '["gcp_service_account_key_json"]' \
  secrets/crossplane-gcp-creds.enc.yaml > /tmp/credentials-raw.json

# REPAIR: SOPS-decrypted JSON has real newlines inside private_key — re-emit as escaped \n
python3 <<'EOF' > /tmp/credentials-clean.json
import re, json
data = open("/tmp/credentials-raw.json").read()
fixed = re.sub(r'"private_key":\s*"((?:[^"\\]|\\.)*)"',
               lambda m: f'"private_key": "{m.group(1).replace(chr(10), chr(92)+chr(110))}"',
               data, flags=re.DOTALL)
print(json.dumps(json.loads(fixed)))
EOF

gcloud compute scp /tmp/credentials-clean.json whisperops-vm:/tmp/ --zone=us-central1-a
```

On the VM:
```bash
sudo kubectl --kubeconfig=/root/.kube/config -n crossplane-system create secret generic gcp-bootstrap-sa-key \
  --from-file=credentials.json=/tmp/credentials-clean.json --dry-run=client -o yaml \
  | sudo kubectl --kubeconfig=/root/.kube/config apply -f -
sudo shred -u /tmp/credentials-clean.json
sudo kubectl --kubeconfig=/root/.kube/config apply -f /tmp/whisperops/platform/crossplane/provider-config.yaml
```

### 0.7 — Bootstrap kagent OpenAI Secret (for querydoc UI sidecar)
```bash
SOPS_AGE_KEY_FILE=/Users/vitorzanoni/whisperops/age.key sops -d secrets/openai.enc.yaml \
  | grep '^OPENAI_API_KEY:' | sed 's/^OPENAI_API_KEY: //' \
  | gcloud compute ssh whisperops-vm --zone=us-central1-a --command='
      read -r KEY
      sudo kubectl --kubeconfig=/root/.kube/config -n kagent-system create secret generic kagent-openai \
        --from-literal=OPENAI_API_KEY="$KEY" --dry-run=client -o yaml \
        | sudo kubectl --kubeconfig=/root/.kube/config apply -f -
      sudo kubectl --kubeconfig=/root/.kube/config -n kagent-system rollout restart deployment kagent
    '
```

### 0.8 — Acceptance check for Phase 0
```bash
# All Crossplane providers Healthy
gcloud compute ssh whisperops-vm --zone=us-central1-a --command='
  sudo kubectl --kubeconfig=/root/.kube/config get providers.pkg.crossplane.io
'
# kagent pod 5/5 Ready
gcloud compute ssh whisperops-vm --zone=us-central1-a --command='
  sudo kubectl --kubeconfig=/root/.kube/config -n kagent-system get pods
'
```

**Estimated effort:** ½ day for first-time operator; 1-2 hours for someone who has done it once.

---

## Phase 1 — Container registry + image pipeline (1-1.5 days)

**Goal:** `docker push gitea.cnoe.localtest.me:8443/whisperops/sandbox:0.1.0` works from the operator workstation, and a kind-cluster Pod can pull from it.

### 1.1 — Architectural decision (small but real)
Pick one:
- **(a) Gitea built-in container registry** — matches CNOE pattern; lives in-cluster; no external dependency. Push/pull via cnoe.localtest.me:8443. Recommended.
- **(b) GHCR** — externally hosted; needs `imagePullSecret` projection per agent namespace; matches kagent's distribution model.
- **(c) GCP Artifact Registry** — most production-realistic; needs Workload Identity wiring on kind nodes; highest setup cost.

This NEXT_STEPS plan assumes **(a)**.

### 1.2 — Enable Gitea container registry
The CNOE-vendored Gitea (`platform/idp/`) doesn't enable the registry by default. Patch the Gitea Application's values to include `gitea.config.packages.ENABLED=true`. Verify by `gitea/api/v1/packages/giteaAdmin?type=container` returning 200.

### 1.3 — Build sandbox image
On the operator workstation (Apple Silicon → must use `--platform=linux/amd64` because kind on the VM runs amd64):
```bash
cd src/sandbox
docker buildx build --platform=linux/amd64 \
  -t gitea.cnoe.localtest.me:8443/whisperops/sandbox:0.1.0 \
  --push .
```

Requires: SSH tunnel to the VM for the cnoe.localtest.me hostname, or push to a registry the VM can reach directly.

### 1.4 — Build chat-frontend image
Same pattern. Note that `src/chat-frontend/Dockerfile` uses a multi-stage build with Next.js standalone output — verify `next.config.ts` has `output: 'standalone'` set (currently does).

### 1.5 — Wire up imagePullSecret (if going off-cluster) or registry mirror config (if Gitea)
For Gitea-internal: kind cluster needs a containerd registry mirror entry pointing `gitea.cnoe.localtest.me:8443` at the in-cluster Gitea Service. Document this as a one-time `containerd config` patch baked into the kind cluster config in `terraform/modules/vm/startup-script.sh`.

### 1.6 — Acceptance check for Phase 1
```bash
gcloud compute ssh whisperops-vm --zone=us-central1-a --command='
  sudo crictl pull gitea.cnoe.localtest.me:8443/whisperops/sandbox:0.1.0
'
# Expect: image pulled, no auth error
```

**Estimated effort:** 1-1.5 days. The decision is fast; the containerd mirror wiring on kind tends to take a few iterations.

---

## Phase 2 — Sandbox MCP server (1-2 days)

**Goal:** the analyst Agent's `tools[].mcpServer.toolNames=[execute_python]` is discovered and callable.

This is **new code**, not a config fix.

### 2.1 — Pick MCP server library
- **`fastmcp`** — built on FastAPI + the official `mcp` Python SDK. Mirrors current sandbox stack. Recommended.
- **Hand-rolled streamable-HTTP** — only if `fastmcp` blocks for some reason.

### 2.2 — Add MCP layer to `src/sandbox/`
Create `src/sandbox/app/mcp_server.py` exposing:
- A single tool `execute_python` with input schema matching the existing `ExecuteRequest` (`code`, `agent_id`, `dataset_id`, `dataset_signed_url`, `agent_bucket`, `sa_key_b64`).
- The tool handler internally calls the same `run_in_subprocess` + `upload_artifacts` pipeline already used by `POST /execute`.
- Mounted at `/mcp` on the same FastAPI app. Both `/execute` (legacy REST, useful for direct test) and `/mcp` (kagent) coexist.

### 2.3 — Update Helm chart values
`platform/helm/sandbox/values.yaml` already has port 8080 and `/healthz` probe. No change needed if the MCP layer mounts at `/mcp` on the same port. Bump `image.tag` to `0.1.1` after rebuild.

### 2.4 — Update skeleton ToolServer
The skeleton `toolserver-sandbox.yaml.njk` already points to `http://sandbox.sandbox.svc.cluster.local:8080/mcp` — no change. Just deploy the sandbox Helm release into a new `sandbox` namespace.

### 2.5 — Deploy sandbox via helmfile or ArgoCD Application
Add a new Helm release in `platform/helmfile.yaml.gotmpl` or (cleaner) a new ArgoCD Application in `platform/argocd/applications/sandbox.yaml`. The latter aligns with DESIGN's intent.

### 2.6 — Acceptance check for Phase 2
```bash
# 1. Sandbox Pod Running
sudo kubectl --kubeconfig=/root/.kube/config -n sandbox get pods
# 2. ToolServer DiscoveredTools populated
sudo kubectl --kubeconfig=/root/.kube/config -n agent-housing-demo get toolserver sandbox -o jsonpath='{.status.discoveredTools}'
# Expect: a list including {"name":"execute_python", ...}
# 3. analyst Agent Accepted=True
sudo kubectl --kubeconfig=/root/.kube/config -n agent-housing-demo get agent analyst -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}'
# Expect: True
```

**Estimated effort:** 1 day for the wrapper itself; +½ day for end-to-end debugging of the kagent ↔ MCP handshake.

---

## Phase 3 — Chat-frontend → kagent session API (1-2 days)

**Goal:** open `https://agent-housing-demo.<vm-ip>.sslip.io`, type a question, see streamed agent responses.

### 3.1 — Discover kagent's actual session API
With kagent v0.4.3 running, port-forward `kagent-system/kagent:80` and probe `/api/v1/...`. Document the exact endpoint shape (sessions, invocations, events) in `docs/runbooks/kagent-api-cheatsheet.md` (new). Pin to v0.4.3 explicitly.

### 3.2 — Rewrite `src/chat-frontend/app/api/chat/route.ts`
Replace the `${PLANNER_URL}/v1/messages` call with:
- `POST /api/v1/sessions` (with body referencing the planner Agent — `agent-housing-demo/planner`).
- `POST /api/v1/sessions/<id>/invocations` (with the user message).
- `GET /api/v1/sessions/<id>/events?stream=true` (consume SSE, translate to the format the existing browser code expects).

### 3.3 — Wire env vars into the Helm chart
The Deployment for chat-frontend (rendered from `chat-frontend.yaml.njk` in the agent's Gitea repo) needs:
- `KAGENT_BASE_URL=http://kagent.kagent-system.svc.cluster.local:80`
- `AGENT_NAMESPACE=agent-housing-demo`
- `PLANNER_AGENT_NAME=planner`

Verify the skeleton `chat-frontend.yaml.njk` exposes these or update it.

### 3.4 — NetworkPolicy egress allowance
The Kyverno-enforced egress policy currently allows only "default-egress" NetworkPolicy in agent namespaces. Add an explicit egress allowance from `agent-housing-demo` to `kagent-system/kagent:80` so the chat-frontend can reach kagent. This is a one-time NetworkPolicy authoring task.

### 3.5 — Acceptance check for Phase 3
```bash
# 1. chat-frontend Pod Running
sudo kubectl --kubeconfig=/root/.kube/config -n agent-housing-demo get pods -l app=chat-frontend
# 2. Open the chat URL in a browser, type "hello"
# Expect: streamed response from the planner Agent
```

**Estimated effort:** 1 day for the route rewrite + ½ day for SSE translation tuning.

---

## Phase 4 — Connect the seams (½-1 day)

Now that all three components exist, wire them together.

### 4.1 — Planner-as-orchestrator
The planner Agent's systemMessage currently asks for a JSON plan. The chat-frontend needs to interpret that plan and call the analyst (with tools) and writer (without tools) Agents accordingly. Two options:
- **(a) Frontend orchestrates.** chat-frontend reads planner output, dispatches to analyst/writer, assembles. Simple but couples UI to agent topology.
- **(b) Planner uses agent-as-tool.** Per kagent's `tools[].type=Agent.ref` schema, the planner can invoke other agents directly. Requires updating planner's systemMessage and adding `tools[]` referencing analyst + writer.

**Recommended:** (b). It keeps the chat-frontend dumb (just talks to one Agent) and pushes orchestration into kagent where it belongs.

### 4.2 — Per-agent observability tagging
DESIGN §13 wanted every span/log/metric tagged with `agent-{name}-{xyz}` and `dataset:{dataset_id}`. Since `Agent.spec.observability` doesn't exist, do this via the OTel Collector resource processor:
- Add a `processors.resource` block keyed off the Pod's namespace label, mapping `agent-{name}` → resource attributes.
- This is one config-map edit on the OTel Collector Helm release.

### 4.3 — Budget controller
DESIGN §10 specified a Python budget-controller running in `whisperops-system` that reads kagent invocation costs from Langfuse and patches `agent-egress-policy` to deny egress when budget is exhausted. **Not implemented today.** Out of scope for "first working demo" — defer to Phase 6.

### 4.4 — Acceptance check for Phase 4
```
# Open chat URL, ask: "What's the median house price in California by latitude?"
# Expect: planner decomposes → analyst runs Python in sandbox → writer composes answer with chart link
# Verify in Langfuse: trace shows planner → analyst (tool: execute_python) → writer
# Verify in Grafana Tempo: all spans tagged agent-housing-demo + dataset:california-housing
```

**Estimated effort:** ½-1 day. Most of this is plumbing once Phases 2-3 are working.

---

## Phase 5 — Hardening for the demo (½ day)

### 5.1 — Make Phase 0 a Makefile target
`make platform-bootstrap` should encapsulate Phase 0 §0.4–0.7 into a single command. The clean-room reproduce should be one `make destroy && make all` cycle.

### 5.2 — `make preflight` extension
The existing `make preflight` checks gcloud, terraform, sops, age. Add:
- `helm` and `helmfile` available locally (if operator builds images locally).
- `docker buildx` available + `linux/amd64` builder configured.
- `age.key` present at the documented path.

### 5.3 — One-page operator runbook
`docs/runbooks/first-time-operator.md` — a single-page guide for "I have whisperops cloned, I have an empty GCP project, what do I do?" Estimated 5-step procedure once the Makefile is hardened.

---

## Phase 6 — Production posture (deferred; multi-week)

Items DESIGN promised, not yet implemented, not on the demo critical path:

- **Budget controller** (DESIGN §10) — Python service in `whisperops-system` reading Langfuse cost rollups and enforcing per-agent budgets via Kyverno mutations.
- **Per-agent OTel attribute tagging** (DESIGN §13) — already partly addressed in Phase 4.2; complete + verify in dashboards.
- **Workload Identity migration** — replace JSON SA keys with Workload Identity Federation. Removes the need for the org-policy override and the SOPS-encrypted key. Big win for the security story.
- **Multi-window-multi-burn-rate SLO alerts** (DESIGN §13) — Prometheus rules + Grafana alerting.
- **Postgres for kagent ModelConfig API key storage** — currently relying on Kubernetes Secret, which is fine for demo, less so for real multi-tenant.
- **CI/CD on commits to `main`** — GitHub Actions to lint Backstage templates, validate Helm charts, run skeleton-render dry-runs. The `.github/` directory exists but is empty.
- **idpbuilder package extras** — fold `kagent`, `crossplane`, `kyverno`, `lgtm`, `otel` into idpbuilder packages so a single `idpbuilder create` brings the entire system up. Removes the helmfile step entirely.

---

## Sequencing summary

```
Phase 0 (clean-room reproduce)      ½ day      [BLOCKER for everything else]
Phase 1 (registry + images)         1-1.5 day  [BLOCKER for Phase 2-3]
Phase 2 (sandbox MCP)               1-2 days   [BLOCKER for analyst tool calls]
Phase 3 (chat-frontend rewrite)     1-2 days   [BLOCKER for user-facing demo]
Phase 4 (connect seams)             ½-1 day    [UNBLOCKS first end-to-end query]
Phase 5 (demo hardening)            ½ day      [UNBLOCKS hand-off / second operator]
─────────────────────────────────────────────
Total to "fully working demo":      4.5-7.5 days of focused work

Phase 6 (production posture)        2-4 weeks  [POST-DEMO]
```

Phases 1+2 can run in parallel by two people; Phase 3 depends on Phase 1 only.

---

## What to read before starting any phase

- **`.claude/sdd/features/DEFINE_whisperops.md`** — what we're building and why. Read the "Assumption Drift" section at the bottom.
- **`.claude/sdd/features/DESIGN_whisperops.md`** — full architecture. Read the Reality Reconciliation Appendix at the bottom for everything that drifted.
- **`docs/SESSION_STATE.md`** — current live state of the deployed system.
- **kagent v0.4.3 CRD reference** — `helm pull oci://ghcr.io/kagent-dev/kagent/helm/kagent-crds --version 0.4.3` then read `kagent-crds/templates/*.yaml`. This is the source of truth for what fields Agents/ToolServers/ModelConfigs accept. Do not trust DESIGN-time assumptions.
