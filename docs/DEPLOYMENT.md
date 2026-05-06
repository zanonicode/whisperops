> **Superseded.** See [docs/OPERATIONS.md §1](OPERATIONS.md#1--end-to-end-deploy-guide) for the current canonical deploy guide.
> The content below is preserved for historical context; some details may be stale post-DESIGN v1.4 (live-deploy reconciliation, DD-15..DD-31).

# Deployment Guide

## Prerequisites

| Tool | Version | Purpose |
|------|---------|---------|
| Terraform | >= 1.9 | GCP cloud floor |
| `gcloud` CLI | latest | GCP authentication |
| `age` | latest | SOPS encryption key management |
| `sops` | >= 3.9 | Secret decryption |
| `helm` | >= 3.16 | Chart linting (optional locally) |
| `kubectl` | >= 1.31 | Cluster interaction post-deploy |

### DNS prerequisite — `*.localtest.me` must resolve to `127.0.0.1`

The in-cluster IDP (idpbuilder) routes ArgoCD, Gitea, and Backstage through `cnoe.localtest.me`, a public DNS entry that points to `127.0.0.1`. Verify:

```bash
dig +short cnoe.localtest.me   # expected: 127.0.0.1
```

If your network filters/rewrites `localtest.me` (some corporate DNS does), fall back to `/etc/hosts`:

```bash
echo "127.0.0.1 cnoe.localtest.me argocd.cnoe.localtest.me gitea.cnoe.localtest.me backstage.cnoe.localtest.me" | sudo tee -a /etc/hosts
```

Without this, the SSH tunnel will work but browsers won't reach the IDP UIs.

## Step 1: Authenticate with GCP

```bash
gcloud auth application-default login
gcloud config set project <YOUR_PROJECT_ID>
```

## Step 2: Configure Terraform backend

Edit `terraform/envs/demo/backend.tfvars` and set `bucket` to your TF state bucket name (the bucket must exist or you must create it manually first).

```bash
gcloud storage buckets create gs://<YOUR_PROJECT_ID>-tfstate \
  --location=us-central1 \
  --uniform-bucket-level-access
```

## Step 3: Initialize and apply Terraform

```bash
cd terraform
terraform init -backend-config=envs/demo/backend.tfvars
terraform plan -var-file=envs/demo/terraform.tfvars
terraform apply -var-file=envs/demo/terraform.tfvars
```

This provisions:
- VPC + subnet + firewall rules
- GCE `e2-standard-8` VM with idpBuilder startup script
- `{project}-datasets` GCS bucket (versioned)
- `whisperops-bootstrap@{project}` service account with scoped IAM roles

## Step 4: Upload datasets

```bash
make upload-datasets
```

This copies all CSV files from `datasets/` to `gs://{project}-datasets/` (flat layout):
- `california-housing-prices.csv`
- `online_retail_II.csv`
- `spotify-tracks.csv`

## Step 5: Decrypt and apply secrets

```bash
# Set your age key path
export SOPS_AGE_KEY_FILE=./age.key

# Decrypt secrets into cluster
make decrypt-secrets
```

This decrypts the SOPS-encrypted files in `secrets/` and applies them as Kubernetes Secrets via ESO.

## Step 6: Bootstrap the platform

Wait for idpBuilder to finish (check VM serial console logs or SSH in):

```bash
# SSH to VM
gcloud compute ssh <vm-name> --zone=us-central1-a

# Check idpBuilder status
journalctl -u idpbuilder -f
```

Once idpBuilder is ready, bootstrap the Helm platform layer:

```bash
make deploy
```

This runs:
1. `helmfile -f platform/helmfile.yaml.gotmpl apply` — deploys Crossplane, Kyverno, LGTM, OTel, kagent, ArgoCD
2. `kubectl apply -f platform/argocd/bootstrap/root-app.yaml` — registers the root ArgoCD app

## Step 7: Register Backstage template

1. Navigate to `https://backstage.<VM_IP>.sslip.io`
2. Go to **Create** → **Register existing component**
3. Enter the Gitea URL to `backstage-templates/dataset-whisperer/template.yaml`
4. Click **Analyze** → **Import**

## Step 8: Run smoke tests

```bash
export CLUSTER_IP=$(terraform output -raw vm_external_ip)
make smoke-test
```

## Teardown

```bash
make destroy
```

## Troubleshooting

See `docs/runbooks/platform-bootstrap.md` for common failure modes.

---

## Appendix A — Vendored CNOE ref-implementation

The platform stack (Backstage, Keycloak, ArgoCD, Gitea, external-secrets, argo-workflows, metric-server, spark-operator) is vendored in `platform/idp/` rather than pulled directly from `cnoe-io/stacks`. This is so we can apply patches that the upstream chart hasn't merged.

**Patches applied:**
- `platform/idp/keycloak/manifests/keycloak-config.yaml` — fix malformed kubectl URL `v1.28.3//bin` → `v1.28.3/bin`. The upstream typo causes the Keycloak bootstrap script to crash silently before creating the `keycloak-clients` K8s Secret, which leaves Backstage's ExternalSecret permanently degraded.

**Important:** the startup script's `IDP_PACKAGE_URL` (in `terraform/files/startup-script.sh`) points at the `whisperops` repo. **The repo must be public** for idpbuilder to clone it from the VM. Make it public with:

```bash
gh repo edit --visibility public
```

If you need to keep the repo private, alternative options:
- Bundle `platform/idp/` into a tarball, upload to a publicly-readable GCS bucket, and pass the GCS URL to idpbuilder.
- Use a deploy key on the VM and switch the startup script to git-clone the repo before invoking idpbuilder with a local path.

---

## Appendix B — Bootstrap SA key: alternative automation (Approach B)

The default flow requires the operator to manually mint and SOPS-encrypt the bootstrap service account key after `terraform apply`:

```bash
gcloud iam service-accounts keys create /tmp/sa-key.json \
  --iam-account=$(terraform output -raw bootstrap_sa_email)
sops secrets/crossplane-gcp-creds.enc.yaml   # paste the JSON
rm /tmp/sa-key.json
git add secrets/crossplane-gcp-creds.enc.yaml && git commit && git push
```

This preserves the GitOps-everywhere pattern (every secret is SOPS-encrypted in git) but is a 2-minute manual step every fresh deploy and a common source of operator error (wrong key pasted, missing newline, etc.).

### Approach B — Terraform-managed SA key

Move key creation into Terraform; have the Makefile inject it into the cluster as a Kubernetes Secret directly. Eliminates the manual step entirely.

**Code changes required:**

```hcl
# terraform/main.tf — add after the IAM module
resource "google_service_account_key" "bootstrap_sa_key" {
  service_account_id = module.bootstrap_sa.email
}

# terraform/outputs.tf — add
output "bootstrap_sa_key_json" {
  value     = base64decode(google_service_account_key.bootstrap_sa_key.private_key)
  sensitive = true
}
```

```makefile
# Makefile — replace the platform-bootstrap target
platform-bootstrap:
	terraform -chdir=$(TERRAFORM_DIR) output -raw bootstrap_sa_key_json | \
	  kubectl create secret generic bootstrap-sa-creds \
	    --from-file=credentials.json=/dev/stdin \
	    --namespace=crossplane-system \
	    --dry-run=client -o yaml | kubectl apply -f -
	# ... existing platform-bootstrap-job apply commands
```

Also remove `secrets/crossplane-gcp-creds.enc.yaml` from the SOPS-required-files check in `.github/workflows/ci.yml` and from the `make preflight` secrets loop.

### Trade-offs

| Aspect | Default flow | Approach B |
|---|---|---|
| Manual steps per fresh deploy | 1 (sops edit) | 0 |
| Where the key lives | SOPS-encrypted in git | Terraform state + K8s Secret |
| Operator error surface | Pasting wrong content into sops editor | None |
| Rotation | Re-run sops edit | `terraform taint google_service_account_key && terraform apply` |
| Consistency with other secrets (anthropic, openai, etc.) | Uniform pattern (all in SOPS) | Split (this one in TF state, others in SOPS) |
| Audit story | git history shows secret rotations | terraform.tfstate shows them |

### When to switch

- **Stay with default** if: you value pattern uniformity (one secret-handling story for all secrets), you have multiple operators who'd see the SOPS-edit step in a runbook anyway, or you're already comfortable with the existing flow.
- **Switch to Approach B** if: you're optimizing for first-shot deploy reliability, the demo audience would notice or be confused by the manual step, or you're moving toward fully-automated environment provisioning (e.g. CI runs `make deploy` against ephemeral projects).

The Approach B implementation is documented but not currently active. The flag-day cost is ~30 min of code changes + one-time migration of the in-use key.

