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
| SOPS key compromise | Low | Critical | Age key not committed (gitignored); rotate via `age-keygen` + `sops updatekeys` |
| Bootstrap SA key compromise | Low | High | Key generated fresh per deploy by `make gcp-bootstrap-key`; ephemeral; no stored encrypted copy can leak |
| Supabase service key exposure | Low | Low | Currently dormant (no runtime consumer); SOPS-encrypted at rest |

## Secret Lifecycle

```
Operator's age key (./age.key — gitignored)
  → SOPS encrypts secrets/{anthropic,langfuse,openai,supabase}.enc.yaml
  → Committed to git (ciphertext only)
  → make deploy invokes Make targets that decrypt and apply during _vm-bootstrap
    (langfuse-secret, _anthropic-secret, gcp-bootstrap-key generates fresh)
  → K8s Secrets in source namespaces (kagent-system, observability,
    crossplane-system)
  → Reflector replicates downstream copies into agent-* namespaces
  → Mounted as env vars or files into Pods (ANTHROPIC_API_KEY env var on
    kagent app + agent pods; ar-pull-secret as imagePullSecrets on agent
    Pod templates; gcp-sa-key as a file mount on the sandbox)
```

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

The bindings are unconditional because IAM Conditions don't gate `*.create` operations: at create time the resource has no name, so any `resource.name.startsWith("agent-")` condition evaluates false and blocks Crossplane's per-agent SA provisioning. The naming convention is enforced at the Backstage scaffolder layer instead. Blast radius is bounded at "who can scaffold via Backstage." A production deployment would re-add Conditions for `get/update/delete` operations (where `resource.name` is populated), or move off kind to GKE Autopilot with Workload Identity.

Per-agent SA (provisioned by Crossplane, one per agent namespace):
- `roles/storage.objectAdmin` on the per-agent bucket only
- `roles/storage.objectViewer` on the shared datasets bucket (one binding per agent; lets the sandbox read CSVs at startup)

## Controls Summary

| Control Category | Implementation |
|-----------------|---------------|
| Network | Kyverno-generated NetworkPolicy; sandbox egress GCS+DNS only |
| Identity | Per-agent GCP SA via Crossplane; short-lived credentials |
| Secrets | SOPS+age for git; ESO for cluster delivery |
| Workload | Non-root, read-only FS, no privilege escalation, seccomp RuntimeDefault |
| Compute | Resource limits enforced; budget controller watchdog |
| Registry | Kyverno allowlist enforced; Gitea as primary registry |
| Cost | Budget annotation required (audit); controller enforces at 100% |

## Residual Risks

1. **Prompt injection via dataset content**: A malicious value in a CSV cell could influence Analyst code generation. Mitigation: sandbox NetworkPolicy restricts egress to GCS + DNS + OTel collector, so an injected `curl http://attacker` cannot reach external hosts.
2. **Project-wide bootstrap SA blast radius**: Unconditional IAM bindings on the bootstrap SA mean that anyone with kubectl access in `crossplane-system` can pivot to provision arbitrary `agent-*`-named resources. Mitigation today is access control on the operator's workstation (gcloud auth + age key). Future mitigation: GKE migration + Workload Identity.
3. **Langfuse cost-tracking latency**: There is a ~60 s delay between LLM spend and budget enforcement. An agent could overspend by up to one poll cycle's worth of queries before scale-to-zero fires. The kill-switch path is also currently fragile and tracked in the internal backlog.
4. **Kind cluster single-node**: No HA; VM failure means full platform downtime. Production would use GKE Autopilot.
5. **sslip.io reveals the VM IP in every hostname**: Acceptable for prototype scope; replace with real wildcard DNS for production.
