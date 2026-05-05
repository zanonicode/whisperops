# Runbook: Platform Bootstrap Failures

## Symptom: `make deploy` fails at Terraform apply

**Check:**
```bash
cd terraform
terraform plan -var-file=envs/demo/terraform.tfvars
```

**Common causes:**

| Error | Resolution |
|-------|-----------|
| `Error: googleapi: Error 403: Required permission...` | Run `gcloud auth application-default login` and ensure the account has `roles/owner` or the specific required roles |
| `Error: state bucket does not exist` | Create the bucket manually: `gcloud storage buckets create gs://{project}-tfstate --location=us-central1` |
| `Error: quota exceeded` | Request quota increase for `compute.googleapis.com/cpus` in the target region |
| Provider version conflict | Run `terraform init -upgrade` |

## Symptom: VM starts but idpBuilder fails

**SSH to VM:**
```bash
gcloud compute ssh <vm-name> --zone=us-central1-a
journalctl -u idpbuilder -n 200
```

**Common causes:**
- Docker daemon not started yet: wait 2-3 minutes after VM boot
- idpBuilder binary download failed: check internet connectivity from VM
- Port 443 conflict: ensure firewall rule allows ingress on 80, 443

## Symptom: ArgoCD root-app not syncing

**Check:**
```bash
kubectl get application root-app -n argocd -o yaml
```

**Common causes:**

| Condition | Resolution |
|-----------|-----------|
| `ComparisonError: repository not found` | Gitea may not be ready; wait 2-3 min and trigger manual sync |
| `ComparisonError: authentication required` | ArgoCD credentials for Gitea are missing; check ESO sync status |
| Apps stuck in `OutOfSync` | Run `kubectl annotate application root-app -n argocd argocd.argoproj.io/refresh=hard` |

## Symptom: Platform bootstrap Job fails

**Check logs:**
```bash
kubectl logs job/platform-bootstrap -n whisperops-bootstrap
```

**Common causes:**

| Error | Resolution |
|-------|-----------|
| `DATASETS_BUCKET env var not set` | Check Helm values: `platform/helm/platform-bootstrap-job/values.yaml` → `datasetsBucket` |
| `403 Forbidden from GCS` | Bootstrap SA key not synced by ESO; check `kubectl get externalsecret -n crossplane-system` |
| `OpenAI APIError: 401` | `openai-credentials` Secret not synced; run `make decrypt-secrets` |
| `Supabase: table dataset_profiles not found` | Supabase table not created; run the SQL migration in Supabase dashboard |
| Job backoff limit exceeded | Check if datasets exist in GCS: `gcloud storage ls gs://{project}-datasets/` |

**Re-run the Job:**
```bash
kubectl delete job platform-bootstrap -n whisperops-bootstrap
kubectl apply -f - <<EOF
# Trigger ArgoCD re-sync
EOF
# Or via ArgoCD UI: Sync with "Force" + "Replace"
```

## Symptom: Crossplane provider-gcp not healthy

```bash
kubectl describe provider.pkg.crossplane.io provider-gcp
```

Check `status.conditions`. If `Unhealthy`:
- Ensure `gcp-bootstrap-sa-key` Secret exists in `crossplane-system`
- Check ESO ExternalSecret: `kubectl get externalsecret gcp-bootstrap-sa-key -n crossplane-system`

## Symptom: Kyverno policies blocking Pods

```bash
kubectl get policyreport -A
kubectl describe policyreport -n <namespace>
```

If a Pod is being blocked by `disallow-privileged` or `require-resource-limits`, check the Pod spec against the policy requirements. Platform Pods should already be compliant. If a third-party chart is blocked, add a namespace exclusion in the relevant Kyverno policy.
