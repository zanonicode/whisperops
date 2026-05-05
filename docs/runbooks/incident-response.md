# Runbook: Incident Response

## Incident: Budget Breach (Agent Spending Over Limit)

### Symptoms
- `AgentBudget80Percent` or `AgentBudget100Percent` alert firing in Grafana
- K8s Warning Event in agent namespace: `whisperops.io/budget-warning`
- Agent Deployments scaled to 0 (for 100% breach)

### Investigation
```bash
# Check current spend status
kubectl get events -n agent-{name}-{suffix} --field-selector reason=BudgetThreshold

# Check which Deployments were scaled
kubectl get deployments -n agent-{name}-{suffix}

# Verify Langfuse for breakdown
# Navigate to https://cloud.langfuse.com → filter by agent tag
```

### Resolution

**Option A: Increase budget** (if spend was legitimate):
1. Edit the kagent Agent CRD annotations: `whisperops.io/budget-usd: "20.00"` (new value)
2. ArgoCD will sync the updated annotation
3. Budget controller will detect new limit on next poll cycle (≤ 60s)
4. Scale Deployments back: `kubectl scale deployment --replicas=1 -n agent-{name}-{suffix} --all`

**Option B: Terminate agent** (if spend was runaway):
1. Delete the agent PR/directory from Gitea
2. ArgoCD prunes all resources
3. Crossplane cleans up GCS bucket and SA

---

## Incident: Sandbox Failures (Timeout Rate Elevated)

### Symptoms
- `SandboxHighTimeoutRate` alert (>10% of executions timing out)
- Agent responses are slow or failing
- Grafana: Sandbox dashboard shows elevated p95 latency

### Investigation
```bash
# Check sandbox Pod health
kubectl get pods -n sandbox
kubectl top pods -n sandbox

# Check for OOM kills
kubectl describe pod <sandbox-pod> -n sandbox | grep -A5 "OOMKilled"

# Check execution logs
kubectl logs deployment/sandbox -n sandbox --tail=100
```

### Resolution

**High timeout rate:**
- If user code is inherently slow (large dataset operations), increase `EXECUTION_TIMEOUT_S` in sandbox values
- If Online Retail II is the culprit (95 MB), consider adding sampling hint to Analyst prompt

**OOM events:**
- Option A: Raise sandbox memory limit from 3GB to 4GB (VM has 32GB headroom):
  ```bash
  kubectl patch deployment sandbox -n sandbox --type='json' \
    -p='[{"op":"replace","path":"/spec/template/spec/containers/0/resources/limits/memory","value":"4Gi"}]'
  ```
- Option B: Enable row sampling in prompt for large datasets (update `agent-prompts` chart)

---

## Incident: Crossplane Stuck Reconciling

### Symptoms
- Crossplane Bucket or ServiceAccount stuck in `Creating` or `Deleting` for >10 minutes
- Agent namespace provisioning blocked

### Investigation
```bash
# Check Crossplane provider health
kubectl get provider.pkg.crossplane.io provider-gcp
kubectl describe provider.pkg.crossplane.io provider-gcp

# Check managed resource conditions
kubectl get bucket -A
kubectl describe bucket agent-{name}-{suffix} -n agent-{name}-{suffix}

# Look for specific errors
kubectl logs deployment/provider-gcp -n crossplane-system | tail -50
```

### Resolution

**Provider-GCP not healthy:**
```bash
# Restart provider Pod
kubectl rollout restart deployment/provider-gcp -n crossplane-system
```

**Resource stuck in Deleting:**
```bash
# Remove finalizer (last resort — data may not be deleted from GCP)
kubectl patch bucket agent-{name}-{suffix} -n agent-{name}-{suffix} \
  --type='json' -p='[{"op":"remove","path":"/metadata/finalizers"}]'
```

**Bootstrap SA key expired:**
- Rotate the SA key: generate new key in GCP Console, encrypt with SOPS, commit
- Re-run `make decrypt-secrets` to update the cluster Secret
- Restart Crossplane provider Pod

---

## Incident: Platform Surface Unreachable

### Quick Checks
```bash
# Is the VM up?
gcloud compute instances describe <vm-name> --zone=us-central1-a | grep status

# Is kind cluster running?
gcloud compute ssh <vm-name> -- kubectl get nodes

# Is NGINX Ingress healthy?
gcloud compute ssh <vm-name> -- kubectl get pods -n ingress-nginx
```

### If VM is down
- Check GCP Compute Engine console for instance status
- If stopped accidentally: `gcloud compute instances start <vm-name> --zone=us-central1-a`
- idpBuilder will restart via systemd on boot

### If NGINX Ingress is down
```bash
kubectl rollout restart deployment ingress-nginx-controller -n ingress-nginx
```

### If cert-manager TLS certificate expired
```bash
kubectl delete certificate <cert-name> -n <namespace>
# cert-manager will reissue automatically
```
