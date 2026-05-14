# Runbook: Langfuse Self-Host Recovery

**Trigger:** Langfuse web or worker pod in `CrashLoopBackOff`, `OOMKilled`, or `ImagePullBackOff`; OTel Collector reporting export failures to Langfuse endpoint.

---

## Component overview

Langfuse runs in the `observability` namespace as two Deployments (`langfuse-web` and `langfuse-worker`), each with a Cloud SQL Auth Proxy sidecar. The proxy connects to `whisperops-langfuse-pg` (Cloud SQL Postgres) using credentials from the `langfuse-postgres-credentials` Secret.

```
langfuse-web pod
├── langfuse (web container)  ← reads DATABASE_URL from Secret
└── cloud-sql-proxy (sidecar) ← opens localhost:5432 → Cloud SQL

langfuse-worker pod
├── langfuse-worker           ← reads DATABASE_URL from Secret
└── cloud-sql-proxy (sidecar)
```

---

## Diagnostic commands

```bash
alias kk='gcloud compute ssh whisperops-vm --zone=us-central1-a --command'

# Pod status
kk 'sudo kubectl get pods -n observability -l app.kubernetes.io/name=langfuse'

# Recent events
kk 'sudo kubectl describe pod -n observability -l app.kubernetes.io/name=langfuse | tail -30'

# Web container logs
kk 'sudo kubectl logs -n observability deploy/langfuse-web -c langfuse --tail=50'

# Cloud SQL Auth Proxy sidecar logs (web pod)
kk 'sudo kubectl logs -n observability deploy/langfuse-web -c cloud-sql-proxy --tail=30'

# Worker container logs
kk 'sudo kubectl logs -n observability deploy/langfuse-worker -c langfuse-worker --tail=50'

# Check Secret exists
kk 'sudo kubectl get secret langfuse-postgres-credentials -n observability -o jsonpath="{.data}" | python3 -m json.tool | grep -oE "\"[A-Z_]+\""'
```

---

## Failure modes and recovery

### 1. `langfuse-postgres-credentials` Secret missing

**Symptom:** Pod events show `secret "langfuse-postgres-credentials" not found`.

**Fix:**
```bash
# Re-run the Makefile target that creates the Secret from tf outputs
make langfuse-pg-key PROJECT_ID=whisperops
```

### 2. Cloud SQL Auth Proxy fails to connect

**Symptom:** Cloud SQL proxy sidecar logs show `error connecting: ... permission denied` or `instance not found`.

**Checks:**

```bash
# Verify the Cloud SQL instance exists
gcloud sql instances describe whisperops-langfuse-pg --project=whisperops

# Verify the proxy SA has roles/cloudsql.client
gcloud projects get-iam-policy whisperops \
  --flatten="bindings[].members" \
  --filter="bindings.members:langfuse-cloudsql-proxy@whisperops.iam.gserviceaccount.com"

# Verify the CLOUD_SQL_INSTANCE value in the Secret is correct
kk 'sudo kubectl get secret langfuse-postgres-credentials -n observability \
  -o jsonpath="{.data.CLOUD_SQL_INSTANCE}" | base64 -d'
# Expected format: whisperops:us-central1:whisperops-langfuse-pg
```

If the SA key is stale (common after `make destroy` + `make deploy`):

```bash
make langfuse-pg-key PROJECT_ID=whisperops
# Then restart Langfuse pods to pick up the new Secret
kk 'sudo kubectl rollout restart deploy/langfuse-web deploy/langfuse-worker -n observability'
```

### 3. Langfuse web pod OOMKilled

**Symptom:** `OOMKilled` in pod events or `exit code 137`.

**Fix:** Increase memory limit for the langfuse container in `platform/observability/langfuse-values.yaml`:

```yaml
web:
  resources:
    limits:
      memory: "2Gi"   # raise from default
```

Then push to Gitea and wait for ArgoCD to sync, or apply directly:

```bash
kk 'sudo helm upgrade langfuse langfuse-k8s/langfuse \
  -n observability \
  -f /tmp/whisperops/platform/observability/langfuse-values.yaml \
  --reuse-values'
```

### 4. OTel Collector cannot reach Langfuse endpoint

**Symptom:** OTel Collector logs show `Exporting failed. Will retry the request after interval. ... otlphttp/langfuse`.

**Checks:**

```bash
# Is langfuse-web service reachable from otel-collector pod?
kk 'sudo kubectl exec -n observability deploy/opentelemetry-collector -- \
  wget -qO- --timeout=5 http://langfuse-web.observability.svc:3000/api/public/health || echo FAIL'

# Check langfuse-web pod is Ready
kk 'sudo kubectl get pods -n observability -l app.kubernetes.io/name=langfuse,component=web'
```

If the Service DNS fails, verify the service name in `otel-collector-values.yaml` exporter section matches the actual Helm-rendered Service name:

```bash
kk 'sudo kubectl get svc -n observability | grep langfuse'
```

### 5. Database schema migration needed (fresh Langfuse install)

On first install, Langfuse runs database migrations automatically at startup. If migrations fail:

```bash
# Web container logs show migration errors
kk 'sudo kubectl logs -n observability deploy/langfuse-web -c langfuse --tail=100 | grep -i migrat'

# Force a clean restart (allow migration to retry)
kk 'sudo kubectl rollout restart deploy/langfuse-web -n observability'
kk 'sudo kubectl rollout status deploy/langfuse-web -n observability'
```

---

## Cloud SQL instance diagnostics

```bash
# Instance status
gcloud sql instances describe whisperops-langfuse-pg \
  --project=whisperops \
  --format='value(state,connectionName,databaseVersion)'

# Recent Cloud SQL operations
gcloud sql operations list \
  --instance=whisperops-langfuse-pg \
  --project=whisperops \
  --limit=5

# Connect directly (useful for schema verification)
gcloud sql connect whisperops-langfuse-pg \
  --user=langfuse \
  --project=whisperops
# Enter the password from: terraform output -raw langfuse_pg_database_url | grep -oP '(?<=:)[^@/]+'
```

---

## Recreating the Langfuse database (data loss — last resort)

If the Cloud SQL instance is corrupted or the password was lost:

1. **Delete the Cloud SQL instance** (operator approval required):
   ```bash
   # Edit terraform/observability.tf to set deletion_protection = false, then:
   terraform -chdir=terraform destroy -target=module.langfuse_postgres
   terraform -chdir=terraform apply -target=module.langfuse_postgres
   ```
2. **Recreate the Secret** — `make langfuse-pg-key PROJECT_ID=whisperops`
3. **Restart Langfuse** — `kk 'sudo kubectl rollout restart deploy/langfuse-web deploy/langfuse-worker -n observability'`

This loses all Langfuse trace history. Tempo traces in GCS are unaffected.

---

## Related

- `platform/observability/langfuse-values.yaml` — Helm values (Auth Proxy sidecar config)
- `terraform/observability.tf` — Cloud SQL instance and SA IAM definition
- `docs/SECRETS.md §4.3` — `langfuse-postgres-credentials` Secret
- `docs/ARCHITECTURE.md §Observability stack` — full component picture
