# Security

## Threat Model

| Threat | Likelihood | Impact | Control |
|--------|-----------|--------|---------|
| Malicious code in Analyst prompt injection | Medium | High | Sandbox network isolation; no shell access; subprocess with limits |
| Per-agent credential exfiltration | Low | High | Per-agent SA key mounted only in the agent's own namespace; NetworkPolicy limits egress |
| Shared dataset bucket exposure | Low | Medium | UBLA-enforced bucket; per-agent SA scoped to its own bucket (admin) plus the shared datasets bucket (read-only) |
| LLM cost runaway | Medium | Medium | budget-controller scales agent Deployments to 0 at 100% spend; per-namespace `whisperops.io/budget-usd` annotation required |
| Privileged container escape | Low | Critical | Pod specs declare `privileged: false`, `allowPrivilegeEscalation: false`, `capabilities: drop: [ALL]` |
| Untrusted image supply chain | Low | High | Per-namespace Kyverno policy allowlist for image registries (currently the namespaced `agent-egress-policy` is enforced; broader cluster-wide policies are in the internal backlog) |
| Cross-agent A2A traffic interception | Low | Medium | A2A flows through kagent-controller :8083 on the cluster pod network; the `allow-a2a` NetworkPolicy generated per-namespace permits cluster pod-CIDR egress on :8083. Controller is the sole listener. Narrowing via pod label selectors is tracked in PENDING.B5. |
| Bootstrap SA key compromise | Low | High | Key generated fresh per deploy by `make gcp-bootstrap-key`; ephemeral; no stored copy can leak |
| Vertex SA key compromise | Low | Medium | Key generated fresh per deploy by `make kagent-vertex-key`; ephemeral; no stored copy can leak. SA has `roles/aiplatform.user` only — cannot access storage, IAM, or other GCP surfaces |
| Observability SA key compromise | Low | Low | `tempo-gcs-credentials`, `grafana-gcm-credentials`, `langfuse-postgres-credentials` keys generated fresh per deploy; scoped to single buckets / read-only monitoring / Cloud SQL Auth Proxy respectively |
| Langfuse application key exposure | Low | Low | Keys issued in the self-hosted UI and entered into client configs by hand; rotate via UI revoke |

## Secret Lifecycle

There is no operator-supplied secret material in this repo. Every credential is generated at deploy time from a Terraform-managed source.

```
Terraform creates SAs + random_password resources
  → make deploy invokes per-SA Makefile targets:
    gcp-bootstrap-key, kagent-vertex-key, tempo-gcs-key, grafana-gcm-key, langfuse-pg-key
  → Each target runs `gcloud iam service-accounts keys create`, scp's the
    JSON to the VM, and applies it as a K8s Secret in the source namespace
    (kagent-system, observability, or crossplane-system)
  → Reflector replicates downstream copies into agent-* namespaces where needed
    (kagent-vertex-credentials, ar-pull-secret)
  → Mounted as env vars or files into Pods (GOOGLE_APPLICATION_CREDENTIALS env var
    + /var/secrets/google volume on kagent + Tempo + Langfuse-proxy containers)
  → On each subsequent deploy, fresh keys are issued and the oldest 7 per SA
    are pruned (GCP 10-keys-per-SA cap)

Langfuse application keys are issued by the operator inside the in-cluster
Langfuse UI on first launch — never stored in git.
```

See [`SECRETS.md`](SECRETS.md) for the full credentials inventory.

## Sandbox Isolation

The sandbox Pod runs with:
- `runAsNonRoot: true`, `runAsUser: 1000`
- `readOnlyRootFilesystem: true`
- `allowPrivilegeEscalation: false`
- `capabilities: drop: [ALL]`
- `/tmp` emptyDir (only writable path)
- `automountServiceAccountToken: false`
- NetworkPolicy: egress to GCS (443) + DNS (53) only

Subprocess limits (per execution):
- CPU: 60s (`setrlimit RLIMIT_CPU`)
- Memory: 4 Gi (`setrlimit RLIMIT_AS`)
- Timeout: 60s (`subprocess.run timeout`)

## IAM Scoping

Bootstrap SA (`whisperops-bootstrap@{project}`) is granted these roles unconditionally:
- `roles/storage.admin`
- `roles/iam.serviceAccountAdmin`
- `roles/iam.serviceAccountKeyAdmin`
- `roles/resourcemanager.projectIamAdmin` (so Crossplane can write `ProjectIAMMember`)
- `roles/artifactregistry.writer`

Kagent Vertex SA (`whisperops-kagent-vertex@{project}`) is granted:
- `roles/aiplatform.user` — the minimum role for Gemini inference. Does not grant `aiplatform.serviceAgent` (fine-tuning) or `aiplatform.admin`. The SA key is mounted on the kagent `app` container and read via `GOOGLE_APPLICATION_CREDENTIALS`.

The bindings are unconditional because IAM Conditions don't gate `*.create` operations: at create time the resource has no name, so any `resource.name.startsWith("agent-")` condition evaluates false and blocks Crossplane's per-agent SA provisioning. The naming convention is enforced at the Backstage scaffolder layer instead. Blast radius is bounded at "who can scaffold via Backstage." A production deployment would re-add Conditions for `get/update/delete` operations (where `resource.name` is populated), or move off kind to GKE Autopilot with Workload Identity.

Per-agent SA (provisioned by Crossplane, one per agent namespace):
- `roles/storage.objectAdmin` on the per-agent bucket only
- `roles/storage.objectViewer` on the shared datasets bucket (one binding per agent; lets the sandbox read CSVs at startup)

## Controls Summary

| Control Category | Implementation |
|-----------------|---------------|
| Network | Kyverno-generated NetworkPolicy; sandbox egress GCS+DNS only |
| Identity | Per-agent GCP SA via Crossplane; short-lived credentials |
| Secrets | Ephemeral SA keys generated per deploy + Terraform random_password for stable PG creds; no git-stored credentials |
| Workload | Non-root, read-only FS, no privilege escalation, seccomp RuntimeDefault |
| Compute | Resource limits enforced; budget controller watchdog |
| Registry | Kyverno allowlist enforced; Gitea as primary registry |
| Cost | Budget annotation required (audit); controller enforces at 100% |

## Residual Risks

1. **Prompt injection via dataset content**: A malicious value in a CSV cell could influence Analyst code generation. Mitigation: sandbox NetworkPolicy restricts egress to GCS + DNS + OTel collector, so an injected `curl http://attacker` cannot reach external hosts.
2. **Project-wide bootstrap SA blast radius**: Unconditional IAM bindings on the bootstrap SA mean that anyone with kubectl access in `crossplane-system` can pivot to provision arbitrary `agent-*`-named resources. Mitigation today is access control on the operator's workstation (gcloud auth + age key). Future mitigation: GKE migration + Workload Identity.
3a. **Vertex SA key blast radius**: The `kagent-vertex-credentials` Secret is replicated to all `agent-*` namespaces via Reflector. A compromised agent-namespace pod that reads its own secret volume could issue Vertex AI calls billed to the project. Mitigation: `roles/aiplatform.user` is inference-only; no storage or IAM access. Future mitigation: per-agent Workload Identity when GKE is available.
3. **Langfuse cost-tracking latency**: There is a ~60 s delay between LLM spend and budget enforcement. An agent could overspend by up to one poll cycle's worth of queries before scale-to-zero fires. The kill-switch path is also currently fragile and tracked in the internal backlog.
4. **Kind cluster single-node**: No HA; VM failure means full platform downtime. Production would use GKE Autopilot.
5. **sslip.io reveals the VM IP in every hostname**: Acceptable for prototype scope; replace with real wildcard DNS for production.
