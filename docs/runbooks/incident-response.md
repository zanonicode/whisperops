# Runbook: Incident Response

## Incident: Budget Breach (Agent Spending Over Limit)

### Symptoms
- `AgentBudget80Percent` or `AgentBudget100Percent` alert firing in Grafana
- K8s Warning Event in agent namespace: `whisperops.io/budget-warning`
- Agent Deployments scaled to 0 (for 100% breach)

### Investigation
```bash
# Check current spend status
kubectl get events -n agent-{name} --field-selector reason=BudgetThreshold

# Check which Deployments were scaled
kubectl get deployments -n agent-{name}

# Verify Langfuse for breakdown
# Navigate to https://us.cloud.langfuse.com → filter by agent tag
```

### Resolution

**Option A: Increase budget** (if spend was legitimate):
1. Edit the namespace annotation: `whisperops.io/budget-usd: "20.00"` (new value)
2. ArgoCD will sync the updated annotation
3. budget-controller will detect the new limit on next poll cycle (≤ 60 s)
4. Scale Deployments back: `kubectl scale deployment --replicas=1 -n agent-{name} --all`

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
# Check sandbox Pod health for the affected agent
kubectl get pods -n agent-{name}
kubectl top pods -n agent-{name}

# Check for OOM kills
kubectl describe pod -n agent-{name} -l app=sandbox | grep -A5 "OOMKilled"

# Check execution logs
kubectl logs deployment/sandbox -n agent-{name} --tail=100
```

### Resolution

**High timeout rate:**
- If user code is inherently slow (large dataset operations), increase `EXECUTION_TIMEOUT_S` env var on the sandbox Deployment for that agent.
- If Online Retail II is the culprit (~95 MB CSV / ~330 MB pandas in memory), consider adding a row-sampling hint to the Analyst prompt.

**OOM events:**
- Sandbox memory limit is 4 Gi today. To raise temporarily for one agent (VM has 32 GB headroom):
  ```bash
  kubectl patch deployment sandbox -n agent-{name} --type='json' \
    -p='[{"op":"replace","path":"/spec/template/spec/containers/0/resources/limits/memory","value":"6Gi"}]'
  ```
- For a permanent change, update the sandbox memory in the Backstage skeleton `sandbox.yaml.njk` and re-scaffold (or `helm template` and `kubectl apply` for an existing agent).
- Alternatively, enable row sampling in the Analyst prompt for large datasets.

---

## Incident: Crossplane Stuck Reconciling

### Symptoms
- Crossplane Bucket or ServiceAccount stuck in `Creating` or `Deleting` for >10 minutes
- Agent namespace provisioning blocked

### Investigation
```bash
# Check Crossplane GCP family providers health
kubectl get providers.pkg.crossplane.io
# Expect: provider-gcp-storage, provider-gcp-iam, provider-gcp-cloudplatform,
# provider-family-gcp — all INSTALLED=True HEALTHY=True

# Check managed resource conditions
kubectl get bucket -A
kubectl describe bucket agent-{name} -n agent-{name}

# Look for specific errors
kubectl logs -n crossplane-system -l pkg.crossplane.io/provider | tail -50
```

### Resolution

**A provider is not healthy:**
```bash
# Force-restart all Crossplane provider Pods (they re-read the SA key Secret on start)
kubectl delete pod -n crossplane-system -l pkg.crossplane.io/provider
```

**Resource stuck in Deleting:**
```bash
# Remove finalizer (last resort — GCP-side resource may not be deleted)
kubectl patch bucket agent-{name} -n agent-{name} \
  --type='json' -p='[{"op":"remove","path":"/metadata/finalizers"}]'
```

**Bootstrap SA key stale or rotated underneath the cluster:**
- The bootstrap SA key is regenerated on every `make deploy` via `make gcp-bootstrap-key`. To rotate mid-cycle:
  ```bash
  make gcp-bootstrap-key PROJECT_ID=<id>
  kubectl delete pod -n crossplane-system -l pkg.crossplane.io/provider
  ```
- Providers re-read the `gcp-bootstrap-sa-key` Secret on container restart.

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
