.DEFAULT_GOAL := help
.PHONY: help preflight deploy destroy smoke-test upload-datasets regenerate-profiles decrypt-secrets lint \
        tf-init tf-plan tf-apply platform-bootstrap

TERRAFORM_DIR := terraform/envs/demo
SECRETS_DIR   := secrets
DATASETS_DIR  := datasets

help:
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-25s\033[0m %s\n", $$1, $$2}'

# ── Pre-flight ─────────────────────────────────────────────────────────────────

preflight: ## Verify the operator's local + GCP environment is ready to deploy
	@echo "→ Pre-flight checks"
	@# 1. gcloud authenticated
	@gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | grep -q . \
		|| (echo "  ✗ gcloud not authenticated; run: gcloud auth application-default login" && exit 1)
	@echo "  ✓ gcloud authenticated"
	@# 2. tfvars has been customised
	@! grep -q "YOUR_GCP_PROJECT_ID" $(TERRAFORM_DIR)/terraform.tfvars 2>/dev/null \
		|| (echo "  ✗ terraform/envs/demo/terraform.tfvars still has placeholder project_id" && exit 1)
	@echo "  ✓ terraform.tfvars customised"
	@! grep -q "YOUR_GCP_PROJECT_ID" $(TERRAFORM_DIR)/backend.tfvars 2>/dev/null \
		|| (echo "  ✗ terraform/envs/demo/backend.tfvars still has placeholder bucket name" && exit 1)
	@echo "  ✓ backend.tfvars customised"
	@# 3. Active project APIs
	@PROJECT=$$(grep -E '^project_id' $(TERRAFORM_DIR)/terraform.tfvars | sed -E 's/.*"([^"]+)".*/\1/'); \
	for api in compute.googleapis.com storage.googleapis.com iam.googleapis.com iamcredentials.googleapis.com; do \
		gcloud services list --enabled --project="$$PROJECT" --filter="config.name=$$api" --format="value(name)" 2>/dev/null | grep -q . \
			|| (echo "  ✗ API not enabled on $$PROJECT: $$api" && exit 1); \
	done; \
	echo "  ✓ Required APIs enabled on project $$PROJECT"
	@# 4. tfstate bucket exists
	@BUCKET=$$(grep -E '^bucket' $(TERRAFORM_DIR)/backend.tfvars | sed -E 's/.*"([^"]+)".*/\1/'); \
	gcloud storage buckets describe "gs://$$BUCKET" --format=none 2>/dev/null \
		|| (echo "  ✗ tfstate bucket gs://$$BUCKET not found — pre-create it manually" && exit 1); \
	echo "  ✓ tfstate bucket gs://$$BUCKET exists"
	@# 5. localtest.me resolves to 127.0.0.1
	@RESOLVED=$$(dig +short cnoe.localtest.me 2>/dev/null | head -1); \
	if [ "$$RESOLVED" != "127.0.0.1" ]; then \
		echo "  ✗ cnoe.localtest.me resolved to '$$RESOLVED' (expected 127.0.0.1) — see README DNS prerequisite section"; \
		exit 1; \
	fi; \
	echo "  ✓ cnoe.localtest.me → 127.0.0.1"
	@# 6. SOPS_AGE_KEY_FILE
	@[ -n "$$SOPS_AGE_KEY_FILE" ] && [ -r "$$SOPS_AGE_KEY_FILE" ] \
		|| (echo "  ✗ SOPS_AGE_KEY_FILE unset or unreadable; export SOPS_AGE_KEY_FILE=$$PWD/age.key" && exit 1)
	@echo "  ✓ SOPS_AGE_KEY_FILE points at a readable key"
	@# 7. Secrets present and encrypted
	@for f in anthropic openai supabase langfuse crossplane-gcp-creds; do \
		[ -f $(SECRETS_DIR)/$$f.enc.yaml ] && grep -q '^sops:' $(SECRETS_DIR)/$$f.enc.yaml \
			|| (echo "  ✗ secrets/$$f.enc.yaml missing or unencrypted" && exit 1); \
	done
	@echo "  ✓ All required SOPS secrets present and encrypted"
	@echo "✓ Pre-flight passed"

# ── Deploy ─────────────────────────────────────────────────────────────────────

deploy: preflight tf-apply platform-bootstrap ## Full deploy: pre-flight → Terraform → platform bootstrap → ArgoCD sync
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

upload-datasets: ## Upload all CSVs from datasets/ to the shared GCS datasets bucket
	@[ -n "$(PROJECT_ID)" ] || (echo "ERROR: PROJECT_ID is not set"; exit 1)
	@BUCKET="$(PROJECT_ID)-datasets"; \
	gcloud storage cp $(DATASETS_DIR)/*.csv gs://$$BUCKET/ && \
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
