# WhisperOps — Dataset Whisperer Platform

An Internal Developer Platform that ships isolated, governed, observable Data Analyst agents over curated datasets. Operators provision agents through a Backstage self-service form; each agent gets a sandboxed Python execution environment, per-agent GCS bucket, LLM budget enforcement, and a chat UI — all GitOps-driven.

## Architecture at a glance

```
Backstage (self-service form)
    └─► Gitea (Git source of truth)
         └─► ArgoCD (GitOps controller)
              ├─► kagent Agents (Planner → Analyst → Writer)
              ├─► Sandbox service (Python execution, 3 GB cgroup)
              ├─► Crossplane (GCS buckets + IAM per agent)
              ├─► Kyverno (policy enforcement)
              └─► LGTM stack (Grafana + Loki + Tempo + Mimir)
```

## Prerequisites

| Tool | Version | Purpose |
|------|---------|---------|
| `terraform` | ≥ 1.7 | Cloud floor provisioning |
| `gcloud` | latest | GCP authentication |
| `age` + `sops` | latest | Secret encryption |
| `kubectl` | ≥ 1.29 | Cluster interaction |
| `helm` | ≥ 3.14 | Chart rendering |
| `helmfile` | ≥ 0.163 | Platform bootstrap |
| `make` | any | Task runner |
| `node` | ≥ 20 | Backstage / TypeScript |
| `python` | 3.12 | Local tooling |

## Quickstart

```bash
# 1. Generate and store your age key (one-time)
age-keygen -o age.key
# Paste the public key into .sops.yaml

# 2. Encrypt your secrets
cp secrets/anthropic.enc.yaml.example secrets/anthropic.enc.yaml
sops --encrypt --in-place secrets/anthropic.enc.yaml
# Repeat for openai, supabase, langfuse, crossplane-gcp-creds

# 3. Deploy everything
make deploy

# 4. Run smoke tests
make smoke-test
```

## Makefile targets

| Target | Description |
|--------|-------------|
| `make deploy` | Full deploy: Terraform → platform bootstrap → ArgoCD sync |
| `make destroy` | Tear down all GCP resources |
| `make smoke-test` | Assert platform up, agents reachable |
| `make upload-datasets` | Unzip and upload CSVs to the shared GCS datasets bucket |
| `make regenerate-profiles` | Re-run platform-bootstrap job to refresh dataset profiles |
| `make decrypt-secrets` | Decrypt all `secrets/*.enc.yaml` to `secrets/*.dec.yaml` (gitignored) |
| `make lint` | Lint Python, TypeScript, Helm charts, Terraform |

## Surface URLs (post-deploy)

| Surface | URL |
|---------|-----|
| Backstage | `http://<vm-ip>/backstage` |
| ArgoCD | `http://<vm-ip>/argocd` |
| Gitea | `http://<vm-ip>/gitea` |
| Grafana | `http://<vm-ip>/grafana` |
| Agent chat | `http://agent-<name>-<suffix>.<base-domain>` |

## Demo

> _Link placeholder — add after first successful deploy._

## Datasets

| Dataset | Source | Size (CSV) |
|---------|--------|------------|
| California Housing | Kaggle | 1.4 MB |
| Online Retail II (UCI) | UCI ML Repository | 95 MB |
| Spotify Tracks | Kaggle | 20 MB |

Upload with `make upload-datasets` after `make deploy` creates the GCS bucket.

## Security notes

- All secrets are encrypted with SOPS + age before commit — never commit plaintext keys
- Sandbox pods run with `readOnlyRootFilesystem`, no SA token mount, 3 GB memory cap
- Per-agent GCS IAM is scoped to `agent-*` buckets only via IAM Conditions
- Kyverno policies enforce resource limits and block privileged containers in all agent namespaces

## License

MIT
