.DEFAULT_GOAL := help
.PHONY: help deploy destroy smoke-test upload-datasets regenerate-profiles decrypt-secrets lint \
        tf-init tf-plan tf-apply platform-bootstrap

TERRAFORM_DIR := terraform/envs/demo
SECRETS_DIR   := secrets
DATASETS_DIR  := datasets

help:
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-25s\033[0m %s\n", $$1, $$2}'

# ── Deploy ─────────────────────────────────────────────────────────────────────

deploy: tf-apply platform-bootstrap ## Full deploy: Terraform → platform bootstrap → ArgoCD sync
	@echo "✓ Deploy complete. Run 'make smoke-test' to verify."

tf-init: ## Initialise Terraform backend
	terraform -chdir=$(TERRAFORM_DIR) init -backend-config=backend.tfvars

tf-plan: tf-init ## Show Terraform plan
	terraform -chdir=$(TERRAFORM_DIR) plan -var-file=terraform.tfvars

tf-apply: tf-init ## Apply Terraform (provisions VM, buckets, IAM)
	terraform -chdir=$(TERRAFORM_DIR) apply -var-file=terraform.tfvars -auto-approve

destroy: ## Tear down all GCP resources
	terraform -chdir=$(TERRAFORM_DIR) destroy -var-file=terraform.tfvars -auto-approve

# ── Platform bootstrap ─────────────────────────────────────────────────────────

platform-bootstrap: ## Run the one-shot Kubernetes bootstrap Job (dataset profiles → Supabase)
	kubectl apply -f platform/helm/platform-bootstrap-job/templates/
	kubectl wait --for=condition=complete job/platform-bootstrap --timeout=300s -n platform

# ── Datasets ───────────────────────────────────────────────────────────────────

upload-datasets: ## Upload local CSVs to the shared GCS datasets bucket
	@[ -n "$(PROJECT_ID)" ] || (echo "ERROR: PROJECT_ID is not set"; exit 1)
	@BUCKET="$(PROJECT_ID)-datasets"; \
	gcloud storage cp $(DATASETS_DIR)/california-housing-prices.csv gs://$$BUCKET/california-housing/housing.csv && \
	gcloud storage cp $(DATASETS_DIR)/online_retail_II.csv          gs://$$BUCKET/online-retail-ii/online_retail_II.csv && \
	gcloud storage cp $(DATASETS_DIR)/spotify-tracks.csv            gs://$$BUCKET/spotify-tracks/dataset.csv && \
	echo "✓ Datasets uploaded to gs://$$BUCKET"

regenerate-profiles: ## Re-run platform-bootstrap to refresh dataset profiles in Supabase
	kubectl delete job platform-bootstrap -n platform --ignore-not-found
	kubectl apply -f platform/helm/platform-bootstrap-job/templates/
	kubectl wait --for=condition=complete job/platform-bootstrap --timeout=300s -n platform

# ── Secrets ────────────────────────────────────────────────────────────────────

decrypt-secrets: ## Decrypt all secrets/*.enc.yaml → secrets/*.dec.yaml (gitignored)
	@for f in $(SECRETS_DIR)/*.enc.yaml; do \
		out=$${f/.enc./.dec.}; \
		sops --decrypt "$$f" > "$$out" && echo "✓ Decrypted: $$out"; \
	done

# ── Lint ───────────────────────────────────────────────────────────────────────

lint: lint-python lint-ts lint-helm lint-terraform ## Run all linters

lint-python: ## Lint Python (ruff + mypy)
	ruff check src/
	mypy src/ --ignore-missing-imports

lint-ts: ## Lint TypeScript (tsc + eslint)
	cd src/chat-frontend && tsc --noEmit
	cd backstage-templates/dataset-whisperer/actions && tsc --noEmit

lint-helm: ## Lint Helm charts
	@for chart in platform/helm/*/; do \
		helm lint "$$chart" && echo "✓ $$chart"; \
	done

lint-terraform: ## Validate Terraform
	terraform -chdir=$(TERRAFORM_DIR) validate

# ── Smoke tests ────────────────────────────────────────────────────────────────

smoke-test: ## Assert platform up, agents reachable, ArgoCD healthy
	bash tests/smoke/platform-up.sh
	bash tests/smoke/agent-creation.sh
	bash tests/smoke/query-roundtrip.sh
