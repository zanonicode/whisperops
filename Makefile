.DEFAULT_GOAL := help
.PHONY: help preflight deploy destroy smoke-test endpoints \
        tf-init tf-plan tf-apply \
        platform-bootstrap regenerate-profiles \
        langfuse-secret kagent-vertex-key \
        external-ingresses \
        drain-crossplane \
        upload-datasets decrypt-secrets \
        lint \
        copy-repo gcp-bootstrap-key build-images deploy-vm _vm-bootstrap \
        _push-whisperops-to-gitea \
        _stop-argocd-apps \
        _drop-argo-workflows-crds \
        _clean-orphan-iam-bindings _clean-orphan-firewalls _clean-orphan-buckets _clean-orphan-sas

TERRAFORM_DIR := terraform
TF_ENV_DIR    := terraform/envs/demo
SECRETS_DIR   := secrets
DATASETS_DIR  := datasets

# Resolve PROJECT_ID from tfvars when the operator did not pass it on the CLI.
TFVARS_PROJECT_ID := $(shell grep -E '^project_id' $(TF_ENV_DIR)/terraform.tfvars 2>/dev/null | sed -E 's/.*"([^"]+)".*/\1/')
PROJECT_ID        ?= $(TFVARS_PROJECT_ID)

# Resolve ZONE from tfvars; fall back to us-central1-a.
TFVARS_ZONE := $(shell grep -E '^zone' $(TF_ENV_DIR)/terraform.tfvars 2>/dev/null | sed -E 's/.*"([^"]+)".*/\1/')
ZONE        := $(if $(TFVARS_ZONE),$(TFVARS_ZONE),us-central1-a)

# VM_IP: auto-derive from Terraform output when not passed explicitly.
VM_IP ?= $$(terraform -chdir=$(TERRAFORM_DIR) output -raw vm_external_ip)

# SSH keepalive flags applied to every gcloud compute ssh call.
# Catches asymmetric SSH death (remote dies, local hangs) within ~90s.
SSH_FLAGS := --ssh-flag="-o ServerAliveInterval=30" --ssh-flag="-o ServerAliveCountMax=3"

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
	@for api in serviceusage.googleapis.com cloudresourcemanager.googleapis.com; do \
		gcloud services list --enabled --project="$(PROJECT_ID)" --filter="config.name=$$api" --format="value(name)" 2>/dev/null | grep -q . \
			|| (echo "  ✗ Bootstrap API not enabled on $(PROJECT_ID): $$api — enable manually: gcloud services enable $$api --project=$(PROJECT_ID)" && exit 1); \
	done
	@echo "  ✓ Bootstrap APIs (serviceusage + cloudresourcemanager) enabled on $(PROJECT_ID); platform APIs are TF-managed"
	@BUCKET=$$(grep -E '^bucket' $(TF_ENV_DIR)/backend.tfvars | sed -E 's/.*"([^"]+)".*/\1/'); \
	gcloud storage buckets describe "gs://$$BUCKET" --format=none 2>/dev/null \
		|| (echo "  ✗ tfstate bucket gs://$$BUCKET not found — pre-create it manually" && exit 1); \
	echo "  ✓ tfstate bucket gs://$$BUCKET exists"
	@RESOLVED=$$(dig +short cnoe.localtest.me 2>/dev/null | head -1); \
	if [ "$$RESOLVED" != "127.0.0.1" ]; then \
	    echo "  ✗ cnoe.localtest.me resolved to '$$RESOLVED' (expected 127.0.0.1) — required for SSH-tunnel access to Backstage/Keycloak"; \
	    exit 1; \
	fi
	@echo "  ✓ cnoe.localtest.me → 127.0.0.1"
	@[ -n "$$SOPS_AGE_KEY_FILE" ] && [ -r "$$SOPS_AGE_KEY_FILE" ] \
		|| (echo "  ✗ SOPS_AGE_KEY_FILE unset or unreadable; export SOPS_AGE_KEY_FILE=$$PWD/age.key" && exit 1)
	@echo "  ✓ SOPS_AGE_KEY_FILE points at a readable key"
	@# The bootstrap SA key is generated fresh per deploy via `make gcp-bootstrap-key` \
	@# rather than stored encrypted: tf-apply recreates the SA on every destroy+create \
	@# cycle, which invalidates any previously-issued key. \
	@for f in openai supabase langfuse; do \
		[ -f $(SECRETS_DIR)/$$f.enc.yaml ] && grep -q '^sops:' $(SECRETS_DIR)/$$f.enc.yaml \
			|| (echo "  ✗ secrets/$$f.enc.yaml missing or unencrypted" && exit 1); \
	done
	@echo "  ✓ All required SOPS secrets present and encrypted"
	@echo "✓ Pre-flight passed"

# ── Deploy ─────────────────────────────────────────────────────────────────────

deploy: preflight tf-apply upload-datasets copy-repo gcp-bootstrap-key kagent-vertex-key build-images deploy-vm endpoints ## Full deploy: preflight → tf-apply → upload-datasets → copy-repo → gcp-bootstrap-key → kagent-vertex-key → build-images → deploy-vm → endpoints
	@# Rollup target — invokes the full chain. Each sub-target is independently
	@# runnable for debugging (e.g. `make build-images` alone after a code change).
	@# Sentinels in copy-repo (SSH:22 wait) and deploy-vm (startup-script-complete
	@# wait) make the chain robust against tf-apply→VM-ready and idpbuilder timing.
	@# platform-bootstrap is invoked INSIDE _vm-bootstrap, not here — it must run
	@# against the kind cluster on the VM, not the operator's local kubectl context.
	@# upload-datasets runs after tf-apply (which creates the bucket) so the shared
	@# CSV data is available before any agent scaffold queries it.
	@echo "✓ Deploy complete. Run 'make smoke-test' to verify."

tf-init: ## Initialise Terraform backend
	terraform -chdir=$(TERRAFORM_DIR) init -backend-config=envs/demo/backend.tfvars

tf-plan: tf-init ## Show Terraform plan
	terraform -chdir=$(TERRAFORM_DIR) plan -var-file=envs/demo/terraform.tfvars

tf-apply: tf-init ## Apply Terraform (provisions VM, buckets, IAM)
	terraform -chdir=$(TERRAFORM_DIR) apply -var-file=envs/demo/terraform.tfvars -auto-approve

# ── VM bring-up ────────────────────────────────────────────────────────────────

copy-repo: ## Rsync local repo to VM (excludes .terraform, .git, secrets/*.dec.yaml, node_modules, macOS metadata)
	@echo "→ Copying repo to whisperops-vm"
	@# After tf-apply returns the VM is RUNNING but sshd may not yet be listening
	@# (30-90s window). Without polling, the tar | ssh below fails fast with
	@# "Network is unreachable" and aborts the whole chain. Poll SSH until it
	@# answers.
	@echo "  ↳ Waiting for SSH on whisperops-vm (up to 5 min)"
	@for i in $$(seq 1 60); do \
		if gcloud compute ssh whisperops-vm --zone=$(ZONE) $(SSH_FLAGS) --command='exit 0' >/dev/null 2>&1; then \
			echo ""; echo "  ✓ SSH ready"; break; \
		fi; \
		if [ "$$i" = "60" ]; then echo ""; echo "  ✗ SSH not ready after 5 min"; exit 1; fi; \
		printf "."; sleep 5; \
	done
	@# COPYFILE_DISABLE=1: macOS bsdtar otherwise injects xattr-derived `._*`
	@# entries into the archive stream that `--exclude='._*'` cannot filter.
	@COPYFILE_DISABLE=1 tar \
		--exclude='.terraform' \
		--exclude='.git' \
		--exclude='node_modules' \
		--exclude='dist' \
		--exclude='__pycache__' \
		--exclude='secrets/*.dec.yaml' \
		--exclude='._*' \
		--exclude='.DS_Store' \
		-czf - . | \
	gcloud compute ssh whisperops-vm --zone=$(ZONE) $(SSH_FLAGS) \
		--command='mkdir -p /tmp/whisperops && tar -xzf - -C /tmp/whisperops'
	@echo "  ✓ Repo copied to /tmp/whisperops on whisperops-vm"

gcp-bootstrap-key: ## Generate fresh whisperops-bootstrap SA key + apply as Secret in crossplane-system
	@# tf-apply destroys + recreates the bootstrap SA on every deploy cycle, which
	@# wipes any previously-issued keys. Encrypting a key in
	@# secrets/crossplane-gcp-creds.enc.yaml goes stale every cycle (key id
	@# mismatch -> "invalid_grant: Invalid JWT Signature" on Crossplane providers,
	@# blocking all GCP-backed agent scaffolds). Instead, generate a fresh key on
	@# each deploy from the operator's authenticated gcloud session, scp to the
	@# VM, and apply directly as the Secret the ProviderConfig already
	@# references. No SOPS, no ExternalSecret, no stale state.
	@[ -n "$(PROJECT_ID)" ] || (echo "ERROR: PROJECT_ID not set" && exit 1)
	@echo "→ Materializing whisperops-bootstrap SA key as gcp-bootstrap-sa-key Secret"
	@# This target runs ~T+2min after VM creation, while cloud-init is still
	@# installing /usr/local/bin/kubectl AND setting up sudo NOPASSWD. Without
	@# this poll, `set -e` correctly aborts on either "sudo: a password is
	@# required" or "kubectl: command not found" — but that breaks the deploy
	@# chain. Mirror copy-repo's SSH:22 poll pattern: wait for cloud-init to
	@# ready the toolchain we need. Budget must accommodate worst-case apt
	@# retries (Ubuntu mirror flakes can stall .deb downloads up to 15min) +
	@# kubectl install + sudoers — 20min = 240 iterations × 5s, aligned with
	@# the cloud-init wait gate budget. We probe `kubectl get nodes` (cluster
	@# API readiness), not just `kubectl version --client`.
	@echo "  ↳ Waiting for cloud-init to ready kubectl + sudo NOPASSWD (up to 20 min)"
	@for i in $$(seq 1 240); do \
		if gcloud compute ssh whisperops-vm --zone=$(ZONE) $(SSH_FLAGS) \
		     --command='sudo -n /usr/local/bin/kubectl get nodes' \
		     >/dev/null 2>&1; then \
			echo ""; echo "  ✓ VM ready (kubectl + sudo NOPASSWD + cluster API)"; break; \
		fi; \
		if [ "$$i" = "240" ]; then echo ""; echo "  ✗ Cloud-init not ready after 20 min — inspect /var/log/syslog AND /var/log/whisperops-bootstrap.log on VM"; exit 1; fi; \
		printf "."; sleep 5; \
	done
	@TMPF=$$(mktemp); trap "rm -f $$TMPF" EXIT; \
	 gcloud iam service-accounts keys create $$TMPF \
		--iam-account=whisperops-bootstrap@$(PROJECT_ID).iam.gserviceaccount.com \
		--project=$(PROJECT_ID) 2>&1 | tail -1; \
	 gcloud compute scp $$TMPF whisperops-vm:/tmp/gcp-bootstrap-key.json --zone=$(ZONE) >/dev/null; \
	 gcloud compute ssh whisperops-vm --zone=$(ZONE) $(SSH_FLAGS) --command=' \
		set -e; \
		sudo /usr/local/bin/kubectl get namespace crossplane-system >/dev/null 2>&1 \
			|| sudo /usr/local/bin/kubectl create namespace crossplane-system; \
		sudo /usr/local/bin/kubectl create secret generic gcp-bootstrap-sa-key -n crossplane-system \
			--from-file=credentials.json=/tmp/gcp-bootstrap-key.json \
			--dry-run=client -o yaml | sudo /usr/local/bin/kubectl apply -f -; \
		rm -f /tmp/gcp-bootstrap-key.json'
	@echo "  ✓ gcp-bootstrap-sa-key Secret applied in crossplane-system"

kagent-vertex-key: ## Generate fresh whisperops-kagent-vertex SA key + apply as Secret in kagent-system
	@# Mirrors gcp-bootstrap-key pattern (CLAUDE.md gotcha #10): ephemeral per
	@# deploy, never SOPS-encrypted. The gcp-bootstrap-key target already polled
	@# cloud-init readiness, so no wait loop needed here.
	@[ -n "$(PROJECT_ID)" ] || (echo "ERROR: PROJECT_ID not set" && exit 1)
	@echo "→ Materializing whisperops-kagent-vertex SA key as kagent-vertex-credentials Secret"
	@TMPF=$$(mktemp); trap "rm -f $$TMPF" EXIT; \
	 gcloud iam service-accounts keys create $$TMPF \
		--iam-account=whisperops-kagent-vertex@$(PROJECT_ID).iam.gserviceaccount.com \
		--project=$(PROJECT_ID) 2>&1 | tail -1; \
	 gcloud compute scp $$TMPF whisperops-vm:/tmp/kagent-vertex-key.json --zone=$(ZONE) >/dev/null; \
	 gcloud compute ssh whisperops-vm --zone=$(ZONE) $(SSH_FLAGS) --command=' \
		set -e; \
		sudo /usr/local/bin/kubectl get namespace kagent-system >/dev/null 2>&1 \
			|| sudo /usr/local/bin/kubectl create namespace kagent-system; \
		sudo /usr/local/bin/kubectl create secret generic kagent-vertex-credentials -n kagent-system \
			--from-file=credentials.json=/tmp/kagent-vertex-key.json \
			--dry-run=client -o yaml \
			| sudo /usr/local/bin/kubectl annotate -f - --local -o yaml \
				reflector.v1.k8s.emberstack.com/reflection-allowed=true \
				reflector.v1.k8s.emberstack.com/reflection-allowed-namespaces="agent-.*" \
				reflector.v1.k8s.emberstack.com/reflection-auto-enabled=true \
				reflector.v1.k8s.emberstack.com/reflection-auto-namespaces="agent-.*" \
			| sudo /usr/local/bin/kubectl apply -f -; \
		rm -f /tmp/kagent-vertex-key.json'
	@echo "  ✓ kagent-vertex-credentials Secret applied in kagent-system (Reflector → agent-*)"

build-images: ## Build whisperops container images on the VM and push to Artifact Registry
	@echo "→ Building whisperops images on whisperops-vm"
	@gcloud compute ssh whisperops-vm --zone=$(ZONE) $(SSH_FLAGS) \
		--command='cd /tmp/whisperops && bash scripts/build-images.sh'
	@echo "  ✓ Image build complete"

deploy-vm: ## Phase 2: SSH into VM and run inside-VM bring-up sequence
	@# copy-repo only waits for SSH:22, but the VM's startup-script keeps running
	@# afterwards: it installs helmfile, sops, kind, then runs `idpbuilder create`
	@# (~5-10 min) and waits up to 900s for all ArgoCD apps to become Synced/Healthy.
	@# _vm-bootstrap below assumes both the tooling and the IDP layer are already
	@# up. Without this wait we get either "helmfile: command not found" (if startup
	@# is still installing) or a missing kubeconfig (if kind cluster isn't created
	@# yet). Block until the startup-script logs its terminal sentinel
	@# "whisperops bootstrap complete".
	@echo "→ Waiting for VM startup-script to complete (IDP layer ready, up to 25 min)"
	@gcloud compute ssh whisperops-vm --zone=$(ZONE) $(SSH_FLAGS) --command=' \
		for i in $$(seq 1 150); do \
			if sudo grep -q "whisperops bootstrap complete" /var/log/whisperops-bootstrap.log 2>/dev/null; then \
				echo ""; echo "  ✓ Startup-script finished (IDP layer Synced/Healthy)"; exit 0; \
			fi; \
			if sudo grep -q "^\[.*\] TIMEOUT:" /var/log/whisperops-bootstrap.log 2>/dev/null; then \
				echo ""; echo "  ✗ Startup-script reported TIMEOUT — inspect /var/log/whisperops-bootstrap.log on VM"; exit 1; \
			fi; \
			if [ "$$(sudo systemctl is-active google-startup-scripts 2>/dev/null)" = "inactive" ] \
			   && ! sudo grep -q "whisperops bootstrap complete" /var/log/whisperops-bootstrap.log 2>/dev/null; then \
				echo ""; echo "  ✗ Startup-script exited without logging completion — inspect /var/log/whisperops-bootstrap.log on VM"; \
				sudo tail -20 /var/log/whisperops-bootstrap.log; exit 1; \
			fi; \
			printf "."; sleep 10; \
		done; \
		echo ""; echo "  ✗ Startup-script did not complete in 25 min"; exit 1 \
	'
	gcloud compute ssh whisperops-vm --zone=$(ZONE) $(SSH_FLAGS) \
		--command='cd /tmp/whisperops && make _vm-bootstrap'

_vm-bootstrap: ## Internal: full bring-up sequence run INSIDE the VM (called by deploy-vm)
	@bash -c 'set -euo pipefail; \
	cd /tmp/whisperops; \
	# kubectl/helm calls inside this target run as the SSH user, whose default \
	# ~/.kube/config does not exist for OS-Login users (causing \
	# "connection refused 127.0.0.1:8080"). Export KUBECONFIG up-front so all \
	# subsequent calls share the cluster-wide kubeconfig. \
	export KUBECONFIG=/root/.kube/config; \
	export HELM_PLUGINS=/usr/local/share/helm/plugins; \
	export SOPS_AGE_KEY_FILE=/tmp/whisperops/age.key; \
	echo "→ Deriving VM_IP from GCP metadata server"; \
	DERIVED_IP=$$(curl -sf -H "Metadata-Flavor: Google" \
		http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip); \
	echo "  VM_IP=$$DERIVED_IP"; \
	echo "→ Deriving PROJECT_ID from GCP metadata server"; \
	PROJECT_ID_DERIVED=$$(curl -sf -H "Metadata-Flavor: Google" \
		http://metadata.google.internal/computeMetadata/v1/project/project-id); \
	echo "  PROJECT_ID=$$PROJECT_ID_DERIVED"; \
	echo "→ Rewriting Backstage host references"; \
	bash platform/scripts/rewrite-backstage-hosts.sh "$$DERIVED_IP"; \
	echo "→ Applying helmfile (application platform layer)"; \
	# helmfile diffs all releases up-front in parallel; some CRDs may not exist \
	# yet on a fresh cluster, so skip-diff-on-install avoids spurious failures. \
	helmfile -f platform/helmfile.yaml.gotmpl apply --skip-diff-on-install; \
	echo "→ Applying kagent-toolserver-secret in kagent namespace (chart ships ToolServer in kagent ns referencing a Secret in kagent-system)"; \
	kubectl apply -f /tmp/whisperops/platform/values/kagent-mcp-grafana-secret.yaml; \
	# Keycloak scale-to-zero is intentionally disabled: Keycloak must stay active \
	# to serve OIDC login via the SSH tunnel. Re-enable only when Backstage moves \
	# to a guest-auth provider that does not require Keycloak. \
	# bash platform/values/keycloak-postrender.sh \
	echo "→ Baking VM IP and project ID into Backstage scaffolder template defaults"; \
	sed -i "s/__BASE_DOMAIN__/$${DERIVED_IP}.sslip.io/g; s/__PROJECT_ID__/$${PROJECT_ID_DERIVED}/g" \
		/tmp/whisperops/platform/idp/backstage-templates/entities/dataset-whisperer/template.yaml; \
	echo "  ✓ Sentinel placeholders replaced in template.yaml"; \
	echo "→ Syncing Backstage templates to Gitea"; \
	{ \
	    GITEA_PASS=$$(kubectl get secret -n gitea gitea-credential -o jsonpath="{.data.password}" | base64 -d); \
	    GITEA_PASS_ENC=$$(printf %s "$${GITEA_PASS}" | jq -sRr @uri); \
	    kubectl port-forward -n gitea svc/my-gitea-http 13000:3000 >/dev/null 2>&1 & PF_PID=$$!; \
	    trap "kill $$PF_PID 2>/dev/null" EXIT INT TERM; \
	    sleep 2; \
	    REPO_DIR=$$(mktemp -d); \
	    git clone "http://giteaAdmin:$${GITEA_PASS_ENC}@127.0.0.1:13000/giteaAdmin/idpbuilder-localdev-backstage-templates-entities.git" "$$REPO_DIR" 2>&1 | tail -3; \
	    rsync -a --delete --exclude='.git' --exclude='._*' --exclude='.DS_Store' platform/idp/backstage-templates/entities/ "$$REPO_DIR/"; \
	    cd "$$REPO_DIR"; \
	    git -c user.email=ci@whisperops.io -c user.name=whisperops-ci add .; \
	    if [ -d .git ] && git diff --cached --quiet; then \
	        echo "  ↳ No template changes to push"; \
	    elif [ -d .git ]; then \
	        git -c user.email=ci@whisperops.io -c user.name=whisperops-ci commit -m "sync Backstage templates from whisperops repo"; \
	        git push origin main 2>&1 | tail -3 && echo "  ✓ Templates synced to Gitea"; \
	    fi; \
	    cd - >/dev/null; rm -rf "$$REPO_DIR"; \
	    kill $$PF_PID 2>/dev/null; trap - EXIT INT TERM; \
	}; \
	echo "→ Pushing whisperops repo to Gitea + applying ArgoCD root-app"; \
	$(MAKE) _push-whisperops-to-gitea; \
	echo "→ Materializing langfuse-credentials Secret"; \
	$(MAKE) langfuse-secret; \
	echo "→ Regenerating external Ingresses"; \
	$(MAKE) external-ingresses VM_IP="$$DERIVED_IP"; \
	echo "→ Materializing whisperops-system Namespace + platform-config skeleton"; \
	kubectl apply -f platform/whisperops-system/platform-config.yaml \
		|| echo "  ⚠ platform-config.yaml apply failed; bring-up continues"; \
	echo "→ Deriving registry_url (PROJECT_ID_DERIVED already set at top of target)"; \
	REGISTRY_URL="us-central1-docker.pkg.dev/$${PROJECT_ID_DERIVED}/whisperops-images"; \
	echo "→ Updating platform-config ConfigMap with live VM IP and registry_url"; \
	kubectl create configmap platform-config -n whisperops-system \
		--from-literal=base_domain="$$DERIVED_IP.sslip.io" \
		--from-literal=registry_url="$$REGISTRY_URL" \
		--dry-run=client -o yaml | kubectl apply -f -; \
	echo "→ Running platform-bootstrap Job (non-fatal — pre-requisites known incomplete)"; \
	kubectl get namespace platform >/dev/null 2>&1 || kubectl create namespace platform; \
	helm template platform-bootstrap platform/helm/platform-bootstrap-job \
		--namespace=platform \
		--set "image.repository=$${REGISTRY_URL}/platform-bootstrap" \
		| kubectl apply -n platform -f - \
		|| echo "  ⚠ platform-bootstrap apply failed; bring-up continues. Fix prereqs and re-run \`make platform-bootstrap\` standalone."; \
	echo "✓ VM bring-up complete"'

_push-whisperops-to-gitea: ## Create whisperops Gitea org+repo, push repo, apply ArgoCD root-app (run inside VM)
	@bash /tmp/whisperops/scripts/push-whisperops-to-gitea.sh

# ── Teardown ───────────────────────────────────────────────────────────────────
# Order: ArgoCD Applications → Crossplane MRs → Terraform. ArgoCD must go
# first or selfHeal recreates the MRs faster than drain can delete them.
# Crossplane must go before Terraform or per-agent GCS buckets / SAs / IAM
# bindings become orphaned (live outside tfstate).
#
# Bucket emptying is handled by `forceDestroy: true` on Crossplane Bucket CRs
# and `force_destroy = true` on the Terraform datasets bucket, so no separate
# empty pass is needed.
#
# Skip flags:
#   SKIP_CROSSPLANE=1   skip _stop-argocd-apps + drain (use when cluster is gone)
#   FORCE=1             skip the interactive confirmation prompt

destroy: ## Tear down EVERYTHING: stop ArgoCD apps → drain Crossplane → terraform destroy
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
	@if [ "$(SKIP_CROSSPLANE)" != "1" ]; then $(MAKE) _stop-argocd-apps; $(MAKE) drain-crossplane; else echo "↳ Skipping Crossplane drain (SKIP_CROSSPLANE=1)"; fi
	$(MAKE) _drop-argo-workflows-crds
	$(MAKE) _clean-orphan-firewalls PROJECT_ID=$(PROJECT_ID)
	terraform -chdir=$(TERRAFORM_DIR) destroy -var-file=envs/demo/terraform.tfvars -auto-approve
	$(MAKE) _clean-orphan-iam-bindings PROJECT_ID=$(PROJECT_ID)
	$(MAKE) _clean-orphan-buckets PROJECT_ID=$(PROJECT_ID)
	$(MAKE) _clean-orphan-sas PROJECT_ID=$(PROJECT_ID)
	@echo "✓ Teardown complete."

_stop-argocd-apps: ## Force-clear ArgoCD Application finalizers and delete all Applications (precedes drain-crossplane)
	@echo "→ Stopping ArgoCD reconciliation (delete all Applications) via VM SSH"
	@# Finalizer-clear before delete: the resources-finalizer.argoproj.io
	@# cascade-deletes child resources, which deadlocks against the same MRs
	@# drain-crossplane is about to delete.
	@if ! gcloud compute instances describe whisperops-vm --zone=$(ZONE) >/dev/null 2>&1; then \
		echo "  ↳ VM does not exist — skipping (cluster already destroyed)"; \
		exit 0; \
	fi; \
	gcloud compute ssh whisperops-vm --zone=$(ZONE) $(SSH_FLAGS) --command=' \
		set -e; \
		APPS=$$(sudo kubectl get app -n argocd -o name 2>/dev/null || true); \
		if [ -z "$$APPS" ]; then \
			echo "  ↳ No ArgoCD Applications found"; \
			exit 0; \
		fi; \
		COUNT=$$(echo "$$APPS" | wc -l | tr -d " "); \
		echo "  ↳ Force-clearing finalizers on $$COUNT Applications"; \
		echo "$$APPS" | while read app; do \
			sudo kubectl patch -n argocd $$app --type=merge -p "{\"metadata\":{\"finalizers\":[]}}" >/dev/null 2>&1 || true; \
		done; \
		echo "  ↳ Deleting all Applications (no-wait — drain-crossplane handles MRs next)"; \
		sudo kubectl delete app -n argocd --all --wait=false --timeout=30s 2>&1 | tail -3; \
		echo "  ✓ ArgoCD reconciliation stopped" \
	'

_drop-argo-workflows-crds: ## Drop Argo Workflows CRDs from the VM-side kind cluster (idempotent)
	@echo "→ Removing Argo Workflows CRDs (via VM SSH)"
	@gcloud compute ssh whisperops-vm --zone=$(ZONE) $(SSH_FLAGS) --command='\
		sudo kubectl delete crd \
			workflows.argoproj.io \
			workflowtemplates.argoproj.io \
			cronworkflows.argoproj.io \
			clusterworkflowtemplates.argoproj.io \
			workfloweventbindings.argoproj.io \
			workflowtaskresults.argoproj.io \
			workflowtasksets.argoproj.io \
			--ignore-not-found 2>/dev/null || true \
	' 2>/dev/null || echo "  ↳ VM unreachable — cluster already destroyed, skipping"
	@echo "  ✓ Argo Workflows CRDs removed (or VM was already gone)"

drain-crossplane: ## Delete all Crossplane GCP Managed Resources on the VM-side cluster and wait for finalizers
	@echo "→ Draining Crossplane Managed Resources (*.gcp.upbound.io) via VM SSH"
	@# kubectl operations MUST go through the VM, not the operator's local kubectl.
	@# A local context may point at an unrelated cluster (EKS, etc.) which would
	@# (a) silently no-op the drain, leaving GCP orphans after terraform destroy,
	@# and (b) destructively act on the wrong cluster. All cluster-state work
	@# happens INSIDE the VM via gcloud compute ssh.
	@# Connectivity check + drain logic must be in ONE recipe line (single subshell)
	@# so the early-exit on VM-gone actually stops execution; multi-line Make recipes
	@# run each line in its own shell, so `exit 0` only exits that line.
	@if ! gcloud compute instances describe whisperops-vm --zone=$(ZONE) >/dev/null 2>&1; then \
		echo "  ↳ VM does not exist — skipping (assumed already destroyed)"; \
		exit 0; \
	fi; \
	gcloud compute ssh whisperops-vm --zone=$(ZONE) $(SSH_FLAGS) --command='\
		set -e; \
		MR_CRDS=$$(sudo kubectl get crd -o name 2>/dev/null | grep -E "\.(gcp\.upbound\.io|gcp\.crossplane\.io)$$" | grep -vE "providerconfig" || true); \
		if [ -z "$$MR_CRDS" ]; then \
			echo "  ↳ No Crossplane GCP managed-resource CRDs found — nothing to drain"; \
			exit 0; \
		fi; \
		for crd in $$MR_CRDS; do \
			KIND=$$(echo $$crd | sed "s|customresourcedefinition.apiextensions.k8s.io/||"); \
			COUNT=$$(sudo kubectl get $$KIND -A --no-headers 2>/dev/null | wc -l | tr -d " "); \
			if [ "$$COUNT" -gt 0 ]; then \
				echo "  ↳ Deleting $$COUNT instance(s) of $$KIND"; \
				sudo kubectl delete $$KIND --all -A --wait=false --timeout=60s 2>/dev/null || true; \
			fi; \
		done; \
		echo "  ↳ Waiting up to 5 min for Crossplane finalizers to release GCP resources..."; \
		for i in $$(seq 1 60); do \
			REMAINING=0; \
			for crd in $$MR_CRDS; do \
				KIND=$$(echo $$crd | sed "s|customresourcedefinition.apiextensions.k8s.io/||"); \
				C=$$(sudo kubectl get $$KIND -A --no-headers 2>/dev/null | wc -l | tr -d " "); \
				REMAINING=$$((REMAINING + C)); \
			done; \
			if [ "$$REMAINING" = "0" ]; then echo "  ✓ All Managed Resources drained"; exit 0; fi; \
			printf "."; sleep 5; \
		done; \
		echo ""; \
		echo "  ⚠ Timed out with Managed Resources still present. Inspect inside VM with:"; \
		echo "      sudo kubectl get managed -A"; \
		echo "  Re-run drain or pass SKIP_CROSSPLANE=1 (will leave GCP orphans)."; \
		exit 1 \
	'

_clean-orphan-firewalls: ## Delete any non-TF firewall rules in whisperops-vpc that would block VPC destroy
	@[ -n "$(PROJECT_ID)" ] || (echo "ERROR: PROJECT_ID not set" && exit 1)
	@echo "→ Cleaning orphan firewall rules in whisperops-vpc + default networks"
	@# Manually-created firewall rules referencing whisperops-vpc are never
	@# imported to TF state. terraform destroy then blocks on
	@# "network resource is already being used by 'firewalls/...'". Delete any
	@# firewall rule referencing whisperops-vpc that TF does not own so the VPC
	@# destroy can proceed cleanly.
	@TF_FW_NAMES=$$(terraform -chdir=$(TERRAFORM_DIR) state list 2>/dev/null | grep firewall | awk -F'"' '{print $$2}' | sort -u); \
	ALL_FW=$$(gcloud compute firewall-rules list --project=$(PROJECT_ID) \
		--filter="network:(whisperops-vpc OR default) AND name~^allow-kind" \
		--format="value(name)" 2>/dev/null); \
	for fw in $$ALL_FW; do \
		if ! echo "$$TF_FW_NAMES" | grep -qx "$$fw"; then \
			echo "  ↳ Deleting orphan firewall: $$fw"; \
			gcloud compute firewall-rules delete "$$fw" --project=$(PROJECT_ID) --quiet 2>&1 | tail -1; \
		fi; \
	done
	@echo "  ✓ Orphan firewall pass complete"

_clean-orphan-iam-bindings: ## Remove project IAM bindings whose principals are 'deleted:' (post-destroy)
	@[ -n "$(PROJECT_ID)" ] || (echo "ERROR: PROJECT_ID not set" && exit 1)
	@echo "→ Cleaning ghost IAM bindings (deleted:* members) in $(PROJECT_ID)"
	@# After terraform destroys SAs, their project-level IAM bindings remain as
	@# "deleted:serviceAccount:...?uid=..." entries. These accumulate across
	@# deploy/destroy cycles — multiple distinct UIDs can appear for the same SA
	@# email after re-deploys. Logic in
	@# platform/scripts/clean-orphan-iam-bindings.py (atomic set-iam-policy).
	@python3 platform/scripts/clean-orphan-iam-bindings.py $(PROJECT_ID)
	@echo "  ✓ Ghost IAM bindings cleaned"

_clean-orphan-buckets: ## Delete agent-* GCS buckets orphaned when SKIP_CROSSPLANE=1 bypasses Crossplane drain
	@[ -n "$(PROJECT_ID)" ] || (echo "ERROR: PROJECT_ID not set" && exit 1)
	@echo "→ Deleting orphan agent-* GCS buckets in $(PROJECT_ID)"
	@# Fallback when SKIP_CROSSPLANE=1 bypasses drain — neither the Crossplane
	@# forceDestroy path nor terraform destroy reaches per-agent buckets, so
	@# this is the only cleanup path. `gcloud storage rm -r` deletes objects
	@# (including versions) and the bucket itself in one call.
	@gcloud storage buckets list --project=$(PROJECT_ID) --format='value(name)' \
		--filter='name:agent-*' 2>/dev/null \
		| while read -r bucket; do \
			echo "  ↳ Deleting orphan Crossplane bucket: gs://$$bucket"; \
			gcloud storage rm -r "gs://$$bucket" --project=$(PROJECT_ID) 2>/dev/null || true; \
		done
	@echo "  ✓ Orphan agent-* bucket pass complete"

_clean-orphan-sas: ## Delete agent-* GCP service accounts orphaned by failed Crossplane finalizers
	@[ -n "$(PROJECT_ID)" ] || (echo "ERROR: PROJECT_ID not set" && exit 1)
	@echo "→ Deleting orphan agent-* service accounts in $(PROJECT_ID)"
	@gcloud iam service-accounts list --project=$(PROJECT_ID) \
		--format='value(email)' --filter='email:agent-*' 2>/dev/null \
		| while read -r sa; do \
			echo "  ↳ Deleting orphan SA: $$sa"; \
			gcloud iam service-accounts delete "$$sa" --project=$(PROJECT_ID) --quiet 2>/dev/null || true; \
		done
	@echo "  ✓ Orphan agent-* SA pass complete"

# ── Platform bootstrap ─────────────────────────────────────────────────────────

platform-bootstrap: ## Run the one-shot Kubernetes bootstrap Job (dataset profiles → Supabase)
	@# The files under templates/ are Helm templates (`{{ .Release.Namespace }}`,
	@# etc.), not rendered K8s manifests. `kubectl apply -f templates/` would choke
	@# on the `{{ }}` syntax — render via `helm template` first.
	@kubectl get namespace platform >/dev/null 2>&1 || kubectl create namespace platform
	@helm template platform-bootstrap platform/helm/platform-bootstrap-job \
		--namespace=platform \
		| kubectl apply -n platform -f -
	@kubectl wait --for=condition=complete job/platform-bootstrap --timeout=300s -n platform

regenerate-profiles: ## Re-run platform-bootstrap to refresh dataset profiles in Supabase
	kubectl delete job platform-bootstrap -n platform --ignore-not-found
	$(MAKE) platform-bootstrap

# ── Langfuse credentials ───────────────────────────────────────────────────────
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
		--dry-run=client -o yaml | kubectl apply -f -; \
	 kubectl annotate secret langfuse-credentials -n observability \
		reflector.v1.k8s.emberstack.com/reflection-allowed="true" \
		reflector.v1.k8s.emberstack.com/reflection-auto-enabled="true" \
		reflector.v1.k8s.emberstack.com/reflection-auto-namespaces="whisperops-system" \
		--overwrite
	@echo "  ✓ langfuse-credentials Secret applied in observability namespace (Reflector annotations set for whisperops-system)"

# ── External access ────────────────────────────────────────────────────────────
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

endpoints: ## Print all platform endpoints + credentials (final step of deploy; run anytime to recall)
	@bash scripts/print-endpoints.sh

# ── Datasets ───────────────────────────────────────────────────────────────────

upload-datasets: ## Upload all CSVs from datasets/ to the shared GCS datasets bucket (idempotent — skips unchanged files)
	@[ -n "$(PROJECT_ID)" ] || (echo "ERROR: PROJECT_ID not set" && exit 1)
	@BUCKET="$(PROJECT_ID)-datasets"; \
	echo "→ Syncing $(DATASETS_DIR)/*.csv → gs://$$BUCKET/ (skips unchanged files)"; \
	gcloud storage rsync --checksums-only $(DATASETS_DIR)/ gs://$$BUCKET/ \
		--exclude=".*DS_Store.*" \
		&& echo "✓ Datasets synced to gs://$$BUCKET"

# ── Secrets ────────────────────────────────────────────────────────────────────

decrypt-secrets: ## Decrypt all secrets/*.enc.yaml → secrets/*.dec.yaml (gitignored)
	@[ -n "$$SOPS_AGE_KEY_FILE" ] && [ -r "$$SOPS_AGE_KEY_FILE" ] \
		|| (echo "ERROR: SOPS_AGE_KEY_FILE unset or unreadable; export SOPS_AGE_KEY_FILE=$$PWD/age.key" && exit 1)
	@for f in $(SECRETS_DIR)/*.enc.yaml; do \
		out=$${f/.enc./.dec.}; \
		sops --decrypt "$$f" > "$$out" && echo "✓ Decrypted: $$out"; \
	done

# ── Lint ───────────────────────────────────────────────────────────────────────

lint: ## Run all linters (Python ruff/mypy + TS tsc + Helm lint + Terraform validate)
	ruff check src/
	mypy src/ --ignore-missing-imports
	cd src/chat-frontend && tsc --noEmit
	@for chart in platform/helm/*/; do \
		helm lint "$$chart" && echo "✓ $$chart"; \
	done
	terraform -chdir=$(TERRAFORM_DIR) validate

# ── Smoke tests ────────────────────────────────────────────────────────────────
# smoke-test runs on the VM (IN_CLUSTER=1) so it can reach the kind cluster's
# kubectl API and port-forward to in-cluster services. Running locally fails
# because the operator's machine has no kube-context pointing at the VM's kind
# cluster. The script is SCP-ed to /tmp then executed via SSH — no permanent
# install needed on the VM.

smoke-test: ## Assert platform up, agents reachable, ArgoCD healthy (runs on VM via SSH)
	@echo "→ Copying smoke-test script to whisperops-vm"
	@gcloud compute scp tests/smoke/platform-up.sh \
		whisperops-vm:/tmp/platform-up.sh --zone=$(ZONE)
	@echo "→ Running smoke-test on VM (IN_CLUSTER=1, KUBECONFIG=/root/.kube/config)"
	@gcloud compute ssh whisperops-vm --zone=$(ZONE) $(SSH_FLAGS) \
		--command='sudo IN_CLUSTER=1 KUBECONFIG=/root/.kube/config bash /tmp/platform-up.sh'
