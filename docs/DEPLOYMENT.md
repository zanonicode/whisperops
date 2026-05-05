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
