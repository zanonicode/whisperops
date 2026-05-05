# Runbook: Agent Creation Failures

## Symptom: Backstage scaffolder task fails

**Check task logs:**
In Backstage → Create → Task logs (task ID from the submission)

**Common failures:**

| Error | Resolution |
|-------|-----------|
| `whisperops:generate-suffix not found` | Scaffolder action not registered; check Backstage backend config includes `generateSuffixAction()` |
| `fetch:template: template not found` | Skeleton path is wrong; verify `backstage-templates/dataset-whisperer/skeleton/` exists in Gitea |
| `publish:gitea: 401 Unauthorized` | Gitea integration credentials missing; check Backstage `integrations.gitea` config |
| `catalog:register: 404` | Gitea repo URL incorrect; verify `agents` repo exists in Gitea `whisperops` org |

## Symptom: Agent namespace never appears (ArgoCD not syncing)

**Check ArgoCD:**
```bash
kubectl get application agents -n argocd -o yaml
```

If the `agents` Application is not watching the right repo path, verify `platform/argocd/applications/agents.yaml` points to the correct Gitea repo URL.

**Manual trigger:**
```bash
kubectl annotate application agents -n argocd argocd.argoproj.io/refresh=hard
```

## Symptom: Crossplane resources stuck in `Creating`

```bash
kubectl get bucket,serviceaccount,serviceaccountkey,projectiammember \
  -n agent-{name}-{suffix}
kubectl describe bucket agent-{name}-{suffix} -n agent-{name}-{suffix}
```

**Common causes:**

| Issue | Resolution |
|-------|-----------|
| `ProviderConfig not found` | Crossplane `provider-gcp` may not be fully healthy; wait and retry |
| `IAM binding quota exceeded` | GCP project IAM policy size limit reached; clean up unused agents |
| `ServiceAccountKey: quota exceeded` | SA key creation limit (10 per SA); rotate or delete old keys |

## Symptom: kagent Agents not starting

```bash
kubectl get agents.kagent.dev -n agent-{name}-{suffix}
kubectl describe agent analyst -n agent-{name}-{suffix}
```

**Common causes:**
- `ANTHROPIC_API_KEY` Secret not present: check ESO sync for `anthropic-credentials`
- Prompt ConfigMap missing: check `prompt-analyst` ConfigMap in `whisperops-system`
- kagent controller not running: `kubectl get pods -n kagent-system`

## Symptom: Chat frontend Ingress not reachable

```bash
kubectl describe ingress agent-{name}-{suffix} -n agent-{name}-{suffix}
```

**Check TLS certificate:**
```bash
kubectl get certificate -n agent-{name}-{suffix}
kubectl describe certificate agent-{name}-{suffix}-tls -n agent-{name}-{suffix}
```

If cert-manager is failing HTTP-01 challenge:
- Ensure the VM's external IP is correctly resolved via sslip.io
- Ensure port 80 is open in the GCP firewall rule

## Deleting an Agent

To clean up a test agent:
1. Delete the agent directory from the Gitea `agents` repo
2. ArgoCD will prune the Application and all resources
3. Crossplane will delete the GCS bucket and SA (if `deletionPolicy: Delete`)

Or via kubectl:
```bash
kubectl delete namespace agent-{name}-{suffix}
# Note: Crossplane resources may need manual cleanup if namespace deletion is blocked
```
