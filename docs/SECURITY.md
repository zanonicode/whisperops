# Security

## Threat Model

| Threat | Likelihood | Impact | Control |
|--------|-----------|--------|---------|
| Malicious code in Analyst prompt injection | Medium | High | Sandbox network isolation; no shell access; subprocess with limits |
| Per-agent credential exfiltration | Low | High | Credentials in `/tmp`, deleted in `finally`; NetworkPolicy limits egress |
| Shared dataset bucket exposure | Low | Medium | IAM Conditions restrict SA to specific bucket prefix; no public access |
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
  → ESO decrypts at runtime using cluster-mounted age key
  → K8s Secrets in specific namespaces
  → Mounted as env vars or files into Pods
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

Bootstrap SA (`whisperops-bootstrap@{project}`):
- `roles/storage.admin` with IAM Condition: `agent-*` and `{project}-agent-*` buckets only
- `roles/iam.serviceAccountAdmin` scoped to `agent-*@` SAs

Per-agent SA:
- `roles/storage.objectViewer` on shared datasets bucket (IAM Condition: bucket prefix)
- `roles/storage.objectAdmin` on per-agent bucket only

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
