.DEFAULT_GOAL := help
.PHONY: help preflight deploy destroy smoke-test \
        tf-init tf-plan tf-apply \
        platform-bootstrap regenerate-profiles \
        ar-pull-secret langfuse-secret \
        external-ingresses \
        empty-buckets drain-crossplane \
        upload-datasets decrypt-secrets \
        lint lint-python lint-ts lint-helm lint-terraform \
        copy-repo deploy-vm _vm-bootstrap \
        _drop-argo-workflows-crds

TERRAFORM_DIR := terraform
TF_ENV_DIR    := terraform/envs/demo
SECRETS_DIR   := secrets
DATASETS_DIR  := datasets
SYSTEM_NS     := whisperops-system
REGION        ?= us-central1

# Resolve PROJECT_ID from tfvars when the operator did not pass it on the CLI.
TFVARS_PROJECT_ID := $(shell grep -E '^project_id' $(TF_ENV_DIR)/terraform.tfvars 2>/dev/null | sed -E 's/.*"([^"]+)".*/\1/')
PROJECT_ID        ?= $(TFVARS_PROJECT_ID)

# Resolve ZONE from tfvars; fall back to us-central1-a.
TFVARS_ZONE := $(shell grep -E '^zone' $(TF_ENV_DIR)/terraform.tfvars 2>/dev/null | sed -E 's/.*"([^"]+)".*/\1/')
ZONE        := $(if $(TFVARS_ZONE),$(TFVARS_ZONE),us-central1-a)

# VM_IP: auto-derive from Terraform output when not passed explicitly.
VM_IP ?= $$(terraform -chdir=$(TERRAFORM_DIR) output -raw vm_external_ip)

help:
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}'

# ── Pre-flight ─────────────────────────────────────────────────────────────────

preflight: ## Verify the operator's local + GCP environment is ready to deploy
	@echo "→ Pre-flight checks"
	@gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | grep -q . \
		|| (echo "  ✗ gcloud not authenticated; run: gcloud auth application-default login" && exit 1)
	@echo "  ✓ gcloud authenticated"
	@! grep -q "YOUR_GCP_PROJECT_ID" $(TF_ENV_DIR)/terraform.tfvars 2>/dev/null \
		|| (echo "  ✗ terraform/envs/demo/terraform.tfvars still has placeholder project_id" && exit 1)
	@echo "  ✓ terraform.tfvars customised"
	@! grep -q "YOUR_GCP_PROJECT_ID" $(TF_ENV_DIR)/backend.tfvars 2>/dev/null \
		|| (echo "  ✗ terraform/envs/demo/backend.tfvars still has placeholder bucket name" && exit 1)
	@echo "  ✓ backend.tfvars customised"
	@for api in compute.googleapis.com storage.googleapis.com iam.googleapis.com iamcredentials.googleapis.com; do \
		gcloud services list --enabled --project="$(PROJECT_ID)" --filter="config.name=$$api" --format="value(name)" 2>/dev/null | grep -q . \
			|| (echo "  ✗ API not enabled on $(PROJECT_ID): $$api" && exit 1); \
	done
	@echo "  ✓ Required APIs enabled on project $(PROJECT_ID)"
	@BUCKET=$$(grep -E '^bucket' $(TF_ENV_DIR)/backend.tfvars | sed -E 's/.*"([^"]+)".*/\1/'); \
	gcloud storage buckets describe "gs://$$BUCKET" --format=none 2>/dev/null \
		|| (echo "  ✗ tfstate bucket gs://$$BUCKET not found — pre-create it manually" && exit 1); \
	echo "  ✓ tfstate bucket gs://$$BUCKET exists"
	@RESOLVED=$$(dig +short cnoe.localtest.me 2>/dev/null | head -1); \
	if [ "$$RESOLVED" != "127.0.0.1" ]; then \
	    echo "  ✗ cnoe.localtest.me resolved to '$$RESOLVED' (expected 127.0.0.1) — required for SSH-tunnel access to Backstage/Keycloak (DD-38 Opção I)"; \
	    exit 1; \
	fi
	@echo "  ✓ cnoe.localtest.me → 127.0.0.1"
	@[ -n "$$SOPS_AGE_KEY_FILE" ] && [ -r "$$SOPS_AGE_KEY_FILE" ] \
		|| (echo "  ✗ SOPS_AGE_KEY_FILE unset or unreadable; export SOPS_AGE_KEY_FILE=$$PWD/age.key" && exit 1)
	@echo "  ✓ SOPS_AGE_KEY_FILE points at a readable key"
	@for f in anthropic openai supabase langfuse crossplane-gcp-creds; do \
		[ -f $(SECRETS_DIR)/$$f.enc.yaml ] && grep -q '^sops:' $(SECRETS_DIR)/$$f.enc.yaml \
			|| (echo "  ✗ secrets/$$f.enc.yaml missing or unencrypted" && exit 1); \
	done
	@echo "  ✓ All required SOPS secrets present and encrypted"
	@echo "✓ Pre-flight passed"

# ── Deploy ─────────────────────────────────────────────────────────────────────

deploy: preflight tf-apply platform-bootstrap ## Full deploy (Phase 1, laptop-side): pre-flight + Terraform + bootstrap Job
	@echo "✓ Phase 1 complete. Run 'make copy-repo && make deploy-vm' for Phase 2 (inside-VM bring-up)."
	@echo "  Then run 'make smoke-test' to verify."

tf-init: ## Initialise Terraform backend
	terraform -chdir=$(TERRAFORM_DIR) init -backend-config=envs/demo/backend.tfvars

tf-plan: tf-init ## Show Terraform plan
	terraform -chdir=$(TERRAFORM_DIR) plan -var-file=envs/demo/terraform.tfvars

tf-apply: tf-init ## Apply Terraform (provisions VM, buckets, IAM)
	terraform -chdir=$(TERRAFORM_DIR) apply -var-file=envs/demo/terraform.tfvars -auto-approve

# ── VM bring-up (DD-34) ────────────────────────────────────────────────────────

copy-repo: ## Rsync local repo to VM (excludes .terraform, .git, secrets/*.dec.yaml, node_modules)
	@echo "→ Copying repo to whisperops-vm"
	@tar \
		--exclude='.terraform' \
		--exclude='.git' \
		--exclude='node_modules' \
		--exclude='dist' \
		--exclude='__pycache__' \
		--exclude='secrets/*.dec.yaml' \
		-czf - . | \
	gcloud compute ssh whisperops-vm --zone=$(ZONE) \
		--command='mkdir -p /tmp/whisperops && tar -xzf - -C /tmp/whisperops'
	@echo "  ✓ Repo copied to /tmp/whisperops on whisperops-vm"

deploy-vm: ## Phase 2: SSH into VM and run inside-VM bring-up sequence
	gcloud compute ssh whisperops-vm --zone=$(ZONE) \
		--command='cd /tmp/whisperops && make _vm-bootstrap'

_vm-bootstrap: ## Internal: full bring-up sequence run INSIDE the VM (called by deploy-vm)
	@bash -c 'set -euo pipefail; \
	cd /tmp/whisperops; \
	echo "→ Deriving VM_IP from GCP metadata server"; \
	DERIVED_IP=$$(curl -sf -H "Metadata-Flavor: Google" \
		http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip); \
	echo "  VM_IP=$$DERIVED_IP"; \
	echo "→ Rewriting Backstage host references (DD-36)"; \
	bash platform/scripts/rewrite-backstage-hosts.sh "$$DERIVED_IP"; \
	echo "→ Applying helmfile (application platform layer)"; \
	KUBECONFIG=/root/.kube/config helmfile -f platform/helmfile.yaml.gotmpl apply; \
	# DD-38: Keycloak scale-to-zero disabled — Opção I keeps Keycloak active for OIDC login via tunnel. \
	# Re-enable when Opção L (custom Backstage image with guest provider) lands. See DESIGN §15 #22. \
	# bash platform/values/keycloak-postrender.sh \
	echo "→ Syncing Backstage templates to Gitea (DD-40)"; \
	{ \
	    GITEA_PASS=$$(kubectl get secret -n gitea gitea-credential -o jsonpath="{.data.password}" | base64 -d); \
	    kubectl port-forward -n gitea svc/my-gitea-http 13000:3000 >/dev/null 2>&1 & PF_PID=$$!; \
	    trap "kill $$PF_PID 2>/dev/null" EXIT INT TERM; \
	    sleep 2; \
	    REPO_DIR=$$(mktemp -d); \
	    git clone "http://giteaAdmin:$${GITEA_PASS}@127.0.0.1:13000/giteaAdmin/idpbuilder-localdev-backstage-templates-entities.git" "$$REPO_DIR" 2>&1 | tail -3; \
	    rsync -a --delete platform/idp/backstage-templates/entities/ "$$REPO_DIR/"; \
	    cd "$$REPO_DIR"; \
	    git -c user.email=ci@whisperops.io -c user.name=whisperops-ci add .; \
	    if git diff --cached --quiet; then \
	        echo "  ↳ No template changes to push"; \
	    else \
	        git -c user.email=ci@whisperops.io -c user.name=whisperops-ci commit -m "DD-40: sync from whisperops repo"; \
	        git push origin main 2>&1 | tail -3 && echo "  ✓ Templates synced to Gitea"; \
	    fi; \
	    cd - >/dev/null; rm -rf "$$REPO_DIR"; \
	    kill $$PF_PID 2>/dev/null; trap - EXIT INT TERM; \
	} || echo "  ⚠ DD-40 Gitea sync failed; bring-up continues"; \
	echo "→ Materializing langfuse-credentials Secret"; \
	$(MAKE) langfuse-secret; \
	echo "→ Regenerating external Ingresses"; \
	$(MAKE) external-ingresses VM_IP="$$DERIVED_IP"; \
	echo "→ Deriving registry_url"; \
	REGISTRY_URL=$$(terraform -chdir=terraform output -raw registry_url 2>/dev/null \
		|| kubectl get configmap platform-config -n whisperops-system \
			-o jsonpath='"'"'{.data.registry_url}'"'"' 2>/dev/null || echo ""); \
	echo "→ Updating platform-config ConfigMap"; \
	kubectl create configmap platform-config -n whisperops-system \
		--from-literal=base_domain="$$DERIVED_IP.sslip.io" \
		--from-literal=registry_url="$$REGISTRY_URL" \
		--dry-run=client -o yaml | kubectl apply -f -; \
	echo "→ Running platform-bootstrap Job"; \
	$(MAKE) platform-bootstrap; \
	echo "✓ VM bring-up complete"'

# ── Teardown (DD-32) ───────────────────────────────────────────────────────────
# Order matters: Crossplane Managed Resources must be drained BEFORE Terraform
# tears down the bootstrap SA / VPC, otherwise GCP resources (per-agent buckets,
# SAs, IAM bindings created by Backstage-scaffolded agents) become orphaned —
# they live outside both tfstate and any remaining controller's reach.
#
# The Terraform-managed datasets bucket sets force_destroy=true (demo-only;
# guarded by the confirmation prompt below). Per-agent artifact buckets created
# by Crossplane are emptied here as defense-in-depth — Crossplane Bucket CRs
# scaffolded by Backstage may not all set the equivalent forceDestroy flag, and
# even with it set, an empty-first pass avoids long deletionTimestamp waits.
#
# Skip flags for partial teardowns:
#   SKIP_CROSSPLANE=1   skip drain step (use when cluster is already gone)
#   SKIP_BUCKETS=1      skip Crossplane-bucket empty step
#   FORCE=1             skip the interactive confirmation prompt

destroy: ## Tear down EVERYTHING: drain Crossplane → empty buckets → terraform destroy
	@[ -n "$(PROJECT_ID)" ] || (echo "ERROR: PROJECT_ID not set and not derivable from terraform.tfvars" && exit 1)
	@if [ "$(FORCE)" != "1" ]; then \
		echo "⚠  This will permanently delete:"; \
		echo "    • All Crossplane Managed Resources in *.gcp.upbound.io ($(PROJECT_ID))"; \
		echo "    • Contents of GCS buckets owned by project $(PROJECT_ID)"; \
		echo "    • All Terraform-managed infrastructure (VM, VPC, SA, datasets bucket, AR repo)"; \
		printf "Type the project id ($(PROJECT_ID)) to confirm: "; \
		read CONFIRM; \
		[ "$$CONFIRM" = "$(PROJECT_ID)" ] || (echo "Aborted." && exit 1); \
	fi
	@if [ "$(SKIP_CROSSPLANE)" != "1" ]; then $(MAKE) drain-crossplane; else echo "↳ Skipping Crossplane drain (SKIP_CROSSPLANE=1)"; fi
	@if [ "$(SKIP_BUCKETS)" != "1" ]; then $(MAKE) empty-buckets PROJECT_ID=$(PROJECT_ID); else echo "↳ Skipping bucket empty (SKIP_BUCKETS=1)"; fi
	$(MAKE) _drop-argo-workflows-crds
	terraform -chdir=$(TERRAFORM_DIR) destroy -var-file=envs/demo/terraform.tfvars -auto-approve
	@echo "✓ Teardown complete."

_drop-argo-workflows-crds: ## Drop Argo Workflows CRDs (idempotent; safe on clusters that never had them)
	@echo "→ Removing Argo Workflows CRDs (DD-35)"
	@kubectl delete crd \
		workflows.argoproj.io \
		workflowtemplates.argoproj.io \
		cronworkflows.argoproj.io \
		clusterworkflowtemplates.argoproj.io \
		workfloweventbindings.argoproj.io \
		workflowtaskresults.argoproj.io \
		workflowtasksets.argoproj.io \
		--ignore-not-found 2>/dev/null || true
	@echo "  ✓ Argo Workflows CRDs removed (or were absent)"

drain-crossplane: ## Delete all Crossplane GCP Managed Resources cluster-wide and wait for finalizers
	@echo "→ Draining Crossplane Managed Resources (*.gcp.upbound.io)"
	@if ! kubectl version --client=false --request-timeout=5s >/dev/null 2>&1; then \
		echo "  ↳ kubectl unreachable — assuming cluster already gone, skipping"; \
		exit 0; \
	fi
	@CRDS=$$(kubectl get crd -o name 2>/dev/null | grep -E '\.(gcp\.upbound\.io|gcp\.crossplane\.io)$$' || true); \
	if [ -z "$$CRDS" ]; then \
		echo "  ↳ No Crossplane GCP CRDs found — nothing to drain"; \
		exit 0; \
	fi; \
	for crd in $$CRDS; do \
		KIND=$$(echo $$crd | sed 's|customresourcedefinition.apiextensions.k8s.io/||'); \
		COUNT=$$(kubectl get $$KIND -A --no-headers 2>/dev/null | wc -l | tr -d ' '); \
		if [ "$$COUNT" -gt 0 ]; then \
			echo "  ↳ Deleting $$COUNT instance(s) of $$KIND"; \
			kubectl delete $$KIND --all -A --wait=false --timeout=60s 2>/dev/null || true; \
		fi; \
	done
	@echo "  ↳ Waiting up to 5 min for Crossplane finalizers to release GCP resources..."
	@for i in $$(seq 1 60); do \
		REMAINING=0; \
		for crd in $$(kubectl get crd -o name 2>/dev/null | grep -E '\.(gcp\.upbound\.io|gcp\.crossplane\.io)$$'); do \
			KIND=$$(echo $$crd | sed 's|customresourcedefinition.apiextensions.k8s.io/||'); \
			C=$$(kubectl get $$KIND -A --no-headers 2>/dev/null | wc -l | tr -d ' '); \
			REMAINING=$$((REMAINING + C)); \
		done; \
		if [ "$$REMAINING" = "0" ]; then echo "  ✓ All Managed Resources drained"; exit 0; fi; \
		printf "."; sleep 5; \
	done; \
	echo ""; \
	echo "  ⚠ Timed out with Managed Resources still present. Inspect with:"; \
	echo "      kubectl get managed -A"; \
	echo "  Re-run 'make drain-crossplane' or pass SKIP_CROSSPLANE=1 to proceed (will leave GCP orphans)."; \
	exit 1

empty-buckets: ## Empty Crossplane-owned GCS buckets in PROJECT_ID (datasets bucket is force_destroy'd by TF)
	@[ -n "$(PROJECT_ID)" ] || (echo "ERROR: PROJECT_ID not set" && exit 1)
	@echo "→ Emptying Crossplane-owned GCS buckets in $(PROJECT_ID)"
	@BUCKETS=$$(gcloud storage buckets list --project=$(PROJECT_ID) --format="value(name)" \
		--filter="labels.managed_by=crossplane" 2>/dev/null); \
	if [ -z "$$BUCKETS" ]; then \
		echo "  ↳ No Crossplane-owned buckets found"; \
		exit 0; \
	fi; \
	for b in $$BUCKETS; do \
		echo "  ↳ Emptying gs://$$b"; \
		gcloud storage rm --recursive "gs://$$b/**" --project=$(PROJECT_ID) 2>/dev/null || \
			echo "    (already empty or not accessible)"; \
	done
	@echo "  ✓ Bucket empty pass complete"

# ── Platform bootstrap ─────────────────────────────────────────────────────────

platform-bootstrap: ## Run the one-shot Kubernetes bootstrap Job (dataset profiles → Supabase)
	kubectl apply -f platform/helm/platform-bootstrap-job/templates/
	kubectl wait --for=condition=complete job/platform-bootstrap --timeout=300s -n platform

regenerate-profiles: ## Re-run platform-bootstrap to refresh dataset profiles in Supabase
	kubectl delete job platform-bootstrap -n platform --ignore-not-found
	$(MAKE) platform-bootstrap

# ── Artifact Registry pull secret (DD-14) ──────────────────────────────────────
# Token from `gcloud auth print-access-token` expires every ~60 minutes; re-run
# whenever chat-frontend / sandbox pods land in ImagePullBackOff.

ar-pull-secret: ## Create/refresh Artifact Registry imagePullSecret in all agent namespaces
	@[ -n "$(PROJECT_ID)" ] || (echo "ERROR: PROJECT_ID not set. Usage: make ar-pull-secret PROJECT_ID=<id>" && exit 1)
	@REGISTRY="$(REGION)-docker.pkg.dev"; \
	TOKEN=$$(gcloud auth print-access-token); \
	NS_LIST=$$(kubectl get namespaces -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | grep '^agent-' || true); \
	if [ -z "$$NS_LIST" ]; then echo "  ↳ No agent-* namespaces found yet (scaffold one via Backstage first)"; exit 0; fi; \
	for NS in $$NS_LIST; do \
		kubectl create secret docker-registry ar-pull-secret \
			--namespace=$$NS \
			--docker-server=$$REGISTRY \
			--docker-username=oauth2accesstoken \
			--docker-password=$$TOKEN \
			--dry-run=client -o yaml | kubectl apply -f -; \
		echo "  ✓ imagePullSecret refreshed in $$NS"; \
	done
	@echo "Token expires in ~60 minutes. Re-run 'make ar-pull-secret' to refresh."

# ── Langfuse credentials (DD-29) ───────────────────────────────────────────────
# SOPS-decrypts secrets/langfuse.enc.yaml → langfuse-credentials Secret in
# observability ns. Used by OTel collector (otlphttp/langfuse exporter) and by
# Grafana (Infinity datasource Basic auth env-var substitution). Re-run after
# rotating Langfuse keys or recreating the cluster.

langfuse-secret: ## Materialize langfuse-credentials Secret from SOPS-encrypted source
	@[ -f $(SECRETS_DIR)/langfuse.enc.yaml ] || (echo "ERROR: $(SECRETS_DIR)/langfuse.enc.yaml not found" && exit 1)
	@[ -n "$$SOPS_AGE_KEY_FILE" ] && [ -r "$$SOPS_AGE_KEY_FILE" ] \
		|| (echo "ERROR: SOPS_AGE_KEY_FILE unset or unreadable; export SOPS_AGE_KEY_FILE=$$PWD/age.key" && exit 1)
	@TMPF=$$(mktemp); trap "rm -f $$TMPF" EXIT; \
	 sops --decrypt $(SECRETS_DIR)/langfuse.enc.yaml > $$TMPF; \
	 PUB=$$(grep '^LANGFUSE_PUBLIC_KEY:' $$TMPF | awk '{print $$2}'); \
	 SEC=$$(grep '^LANGFUSE_SECRET_KEY:' $$TMPF | awk '{print $$2}'); \
	 HOST=$$(grep '^LANGFUSE_HOST:' $$TMPF | awk '{print $$2}'); \
	 OTLP="$$HOST/api/public/otel"; \
	 BASIC=$$(printf "%s:%s" "$$PUB" "$$SEC" | base64 | tr -d '\n'); \
	 kubectl create secret generic langfuse-credentials -n observability \
		--from-literal=LANGFUSE_PUBLIC_KEY="$$PUB" \
		--from-literal=LANGFUSE_SECRET_KEY="$$SEC" \
		--from-literal=LANGFUSE_HOST="$$HOST" \
		--from-literal=LANGFUSE_OTLP_ENDPOINT="$$OTLP" \
		--from-literal=LANGFUSE_BASIC_AUTH="$$BASIC" \
		--dry-run=client -o yaml | kubectl apply -f -
	@echo "  ✓ langfuse-credentials Secret applied in observability namespace"

# ── External access (DD-23, DD-26) ─────────────────────────────────────────────
# Used during the regular bring-up (Stage 7 in docs/OPERATIONS.md) immediately
# after `make tf-apply` to pin the new VM IP into platform Ingress hosts.
# A separate `kubectl create configmap platform-config ...` step (also in
# Stage 7) updates the Backstage scaffolder default — kept manual so the
# operator stays aware of the registry_url + base_domain pairing.

external-ingresses: ## Regenerate platform/external-access/ingresses.yaml for new VM_IP and apply
	@[ -n "$(VM_IP)" ] || (echo "ERROR: VM_IP not set. Usage: make external-ingresses VM_IP=<ip>" && exit 1)
	@OLD_IP=$$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\.sslip\.io' platform/external-access/ingresses.yaml | head -1 | sed 's/\.sslip\.io//'); \
	 if [ -z "$$OLD_IP" ]; then echo "ERROR: could not detect existing IP in ingresses.yaml" && exit 1; fi; \
	 echo "  Old IP: $$OLD_IP -> New IP: $(VM_IP)"; \
	 sed -i.bak "s/$$OLD_IP\.sslip\.io/$(VM_IP).sslip.io/g" platform/external-access/ingresses.yaml; \
	 rm -f platform/external-access/ingresses.yaml.bak; \
	 kubectl apply -f platform/external-access/ingresses.yaml
	@echo "  ✓ Platform Ingresses regenerated and applied"

# ── Datasets ───────────────────────────────────────────────────────────────────

upload-datasets: ## Upload all CSVs from datasets/ to the shared GCS datasets bucket
	@[ -n "$(PROJECT_ID)" ] || (echo "ERROR: PROJECT_ID not set" && exit 1)
	@BUCKET="$(PROJECT_ID)-datasets"; \
	gcloud storage cp $(DATASETS_DIR)/*.csv gs://$$BUCKET/ && \
	echo "✓ Datasets uploaded to gs://$$BUCKET"

# ── Secrets ────────────────────────────────────────────────────────────────────

decrypt-secrets: ## Decrypt all secrets/*.enc.yaml → secrets/*.dec.yaml (gitignored)
	@[ -n "$$SOPS_AGE_KEY_FILE" ] && [ -r "$$SOPS_AGE_KEY_FILE" ] \
		|| (echo "ERROR: SOPS_AGE_KEY_FILE unset or unreadable; export SOPS_AGE_KEY_FILE=$$PWD/age.key" && exit 1)
	@for f in $(SECRETS_DIR)/*.enc.yaml; do \
		out=$${f/.enc./.dec.}; \
		sops --decrypt "$$f" > "$$out" && echo "✓ Decrypted: $$out"; \
	done

# ── Lint ───────────────────────────────────────────────────────────────────────

lint: lint-python lint-ts lint-helm lint-terraform ## Run all linters

lint-python: ## Lint Python (ruff + mypy)
	ruff check src/
	mypy src/ --ignore-missing-imports

lint-ts: ## Type-check TypeScript (tsc --noEmit)
	cd src/chat-frontend && tsc --noEmit

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
