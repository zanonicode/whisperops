# Security

## Threat Model

| Threat | Likelihood | Impact | Control |
|--------|-----------|--------|---------|
| Malicious code in Analyst prompt injection | Medium | High | Sandbox network isolation; no shell access; subprocess with limits |
| Per-agent credential exfiltration | Low | High | Credentials in `/tmp`, deleted in `finally`; NetworkPolicy limits egress |
| Shared dataset bucket exposure | Low | Medium | UBLA-enforced bucket; per-agent SA scoped to its own bucket only; no public access. (IAM Conditions removed in DD-19 — they evaluate empty `resource.name` on `*.create` and broke Crossplane reconciliation. Residual project-wide write blast radius is accepted for v0.3 prototype; production should re-add Conditions on `get/update/delete` only or use VPC-SC.) |
| LLM cost runaway | Medium | Medium | Budget controller scales to 0 at 100%; annotation required (Kyverno audit) |
| Privileged container escape | Low | Critical | Kyverno disallows `privileged: true`, host namespaces |
| Untrusted image supply chain | Low | High | Kyverno registry allowlist: Gitea + approved upstreams |
| SOPS key compromise | Low | Critical | Age key not committed (gitignored); rotate via `age-keygen` + re-encrypt |
| Supabase service key exposure | Low | High | SOPS-encrypted at rest; ESO syncs into cluster; never in git plaintext |

## Secret Lifecycle

```
Operator's age key (./age.key — gitignored)
  → SOPS encrypts secrets/*.enc.yaml
  → Committed to git (ciphertext only)
  → Operator runs `make langfuse-secret` / `make ar-pull-secret` /
    `kubectl apply <(sops --decrypt …)` on each fresh deploy (DD-29)
  → K8s Secrets in specific namespaces (kagent-system, observability,
    crossplane-system, whisperops-system, agent-*)
  → Mounted as env vars or files into Pods (DD-20 ANTHROPIC_API_KEY env var
    on kagent app container, DD-18 imagePullSecrets on Pod template)
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
- Memory: 3 GB (`setrlimit RLIMIT_AS`)
- Timeout: 60s (`subprocess.run timeout`)

## IAM Scoping

Bootstrap SA (`whisperops-bootstrap@{project}`) — DD-19 removed IAM
Conditions because they break Crossplane on `*.create`:
- `roles/storage.admin` (project-wide; production should add Conditions on
  `get/update/delete` only)
- `roles/iam.serviceAccountAdmin` (project-wide)
- `roles/iam.serviceAccountKeyAdmin` (project-wide)
- `roles/resourcemanager.projectIamAdmin` (DD-19 — required so Crossplane
  can write `ProjectIAMMember` resources)

Per-agent SA (provisioned by Crossplane, one per agent namespace):
- `roles/storage.objectAdmin` on the per-agent bucket only
- `roles/storage.objectViewer` on the shared datasets bucket (one per agent;
  scoped to read the dataset CSVs at sandbox startup)

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

1. **Prompt injection via dataset content**: A malicious value in a CSV cell could influence Analyst code generation. Mitigation: sandbox network isolation limits blast radius; no shell access.
2. **Shared sandbox pool**: Multiple agents share the same sandbox Pods. Isolation is process-level (subprocess), not container-level. Future mitigation: one sandbox Pod per agent namespace.
3. **Langfuse cost tracking latency**: There is a ~60s delay between LLM spend and budget enforcement. An agent could overspend by up to 1 poll cycle's worth of queries.
4. **Kind cluster single-node**: No HA; VM failure means full platform downtime. Production would use GKE Autopilot.
