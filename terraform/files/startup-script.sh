#!/usr/bin/env bash
set -euo pipefail

LOGFILE="/var/log/whisperops-bootstrap.log"
IDPBUILDER_VERSION="v0.10.2"
IDPBUILDER_ARCH="linux-amd64"

# Vendored CNOE ref-implementation (forked from cnoe-io/stacks at 2026-05-05).
# Patches applied:
#   - keycloak/manifests/keycloak-config.yaml: fix malformed kubectl URL
#     (v1.28.3//bin → v1.28.3/bin) that caused the bootstrap script to
#     crash silently before creating the keycloak-clients K8s secret.
# IMPORTANT: This URL requires the whisperops repo to be public. If kept
# private, switch to a GCS-bundled alternative (see docs/DEPLOYMENT.md).
IDP_PACKAGE_URL="https://github.com/zanonicode/whisperops//platform/idp"

# Maximum time to wait for all ArgoCD apps to become Synced/Healthy.
PLATFORM_READY_TIMEOUT=1500

log() {
  echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*" | tee -a "${LOGFILE}"
}

log "Starting whisperops bootstrap"

# 1. System packages
log "Installing system packages"
apt-get update -qq
# Ubuntu mirror flakes can stall .deb downloads mid-stream (TCP ESTABLISHED but
# zero bytes flowing) for 15+ minutes. apt's built-in retry catches failed
# connects but not stalled connections. Wrap in a bounded retry loop that
# refreshes metadata and retries up to 3 times so cloud-init never hangs
# indefinitely on a single broken mirror.
for attempt in 1 2 3; do
    if apt-get install -y docker.io git curl jq make; then
        log "apt-get install succeeded on attempt $attempt"
        break
    fi
    log "apt-get install failed on attempt $attempt/3 — refreshing metadata, retry in 30s"
    sleep 30
    apt-get update -qq || true
    if [ "$attempt" = "3" ]; then
        log "ERROR: apt-get install of base packages failed after 3 attempts"
        exit 1
    fi
done

# 2. Docker
log "Enabling Docker"
systemctl enable --now docker

# 3a. kubectl (idpbuilder ships kind but not kubectl, and we need it for ops + the wait gate)
log "Installing kubectl"
KUBECTL_VERSION="$(curl -fsSL https://dl.k8s.io/release/stable.txt)"
curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" -o /tmp/kubectl
install -m 0755 /tmp/kubectl /usr/local/bin/kubectl
rm /tmp/kubectl

# 3a.1. helm + helmfile + sops (needed by _vm-bootstrap Makefile target)
# _vm-bootstrap calls helmfile + sops; bake them into the startup-script so the
# operator never has to install them by hand.
log "Installing helm"
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

log "Installing helmfile"
# Pin the version: resolving the latest tag via
#   `curl api.github.com/.../releases/latest | grep -m1 tag_name | sed ...`
# races with `set -o pipefail` — `grep -m1` closes the pipe while curl is
# still writing, the pipeline inherits curl's SIGPIPE exit (23), and `set -e`
# aborts the whole script. Pinning is faster (no API call), reproducible, and
# avoids the race entirely.
HELMFILE_VERSION="1.5.0"
curl -fsSL "https://github.com/helmfile/helmfile/releases/download/v${HELMFILE_VERSION}/helmfile_${HELMFILE_VERSION}_linux_amd64.tar.gz" \
    | tar -xz -C /usr/local/bin helmfile
chmod +x /usr/local/bin/helmfile

log "Installing sops"
# Same SIGPIPE risk as helmfile above — pin to a known-good version.
SOPS_VERSION="3.12.2"
curl -fsSL "https://github.com/getsops/sops/releases/download/v${SOPS_VERSION}/sops-v${SOPS_VERSION}.linux.amd64" \
    -o /usr/local/bin/sops
chmod +x /usr/local/bin/sops

log "Installing yq"
# Required by the kagent helmfile postRenderer that strips a duplicated
# AUTOGEN_DISABLE_RUNTIME_TRACING env entry. Without yq on PATH, the
# postRenderer fails silently during `helmfile apply`, helmfile records kagent
# as "deployed" in its state but the actual helm install never runs — cluster
# ends up with zero kagent pods, zero kagent.dev CRDs. Helmfile `wait: true`
# does NOT catch this because the postRenderer returns 0 even when yq is
# missing.
YQ_VERSION="4.45.1"
curl -fsSL "https://github.com/mikefarah/yq/releases/download/v${YQ_VERSION}/yq_linux_amd64" \
    -o /usr/local/bin/yq
chmod +x /usr/local/bin/yq

log "Installing helm-diff plugin to /usr/local/share/helm/plugins (system-wide, required by helmfile)"
# Install to the system-wide location, not $HOME/.local/share/helm/plugins:
# a plugin under /root is mode 700 and unreadable by the SSH OS-Login user
# helmfile actually runs as. The Makefile sets
# HELM_PLUGINS=/usr/local/share/helm/plugins to point helm at this location.
mkdir -p /usr/local/share/helm/plugins
HELM_DATA_HOME=/usr/local/share/helm helm plugin install https://github.com/databus23/helm-diff 2>&1 || \
    log "  helm-diff plugin already installed or failed (non-fatal)"
chmod -R a+rx /usr/local/share/helm/plugins

# 3b. Download idpBuilder (released as a tarball since v0.10.x)
log "Downloading idpBuilder ${IDPBUILDER_VERSION}"
IDPBUILDER_URL="https://github.com/cnoe-io/idpbuilder/releases/download/${IDPBUILDER_VERSION}/idpbuilder-${IDPBUILDER_ARCH}.tar.gz"
TMPDIR="$(mktemp -d)"
curl -fsSL "${IDPBUILDER_URL}" -o "${TMPDIR}/idpbuilder.tar.gz"
tar -xzf "${TMPDIR}/idpbuilder.tar.gz" -C "${TMPDIR}"
install -m 0755 "${TMPDIR}/idpbuilder" /usr/local/bin/idpbuilder
rm -rf "${TMPDIR}"
log "idpbuilder installed at $(which idpbuilder)"

# 4. Bootstrap the in-cluster IDP using our vendored ref-implementation
log "Running idpbuilder create against ${IDP_PACKAGE_URL}"
idpbuilder create \
  --use-path-routing \
  -p "${IDP_PACKAGE_URL}"
log "idpbuilder create completed"

# 5. Distribute kubeconfig to ubuntu user
log "Distributing kubeconfig to ubuntu user"
mkdir -p /home/ubuntu/.kube
if [ -f /root/.kube/config ]; then
  cp /root/.kube/config /home/ubuntu/.kube/config
elif [ -f /.kube/config ]; then
  # idpbuilder ran with HOME=/ (no per-user home); kubeconfig landed at /.kube/config
  mkdir -p /root/.kube
  cp /.kube/config /root/.kube/config
  cp /.kube/config /home/ubuntu/.kube/config
else
  log "ERROR: kubeconfig not found at /root/.kube/config or /.kube/config"
  exit 1
fi
chown ubuntu:ubuntu /home/ubuntu/.kube/config
chmod 600 /home/ubuntu/.kube/config

# Make /root/.kube/config readable by the OS-Login SSH user (different per operator).
# /root/.kube/config defaults to mode 600 and is unreadable by the SSH user
# invoking helmfile via _vm-bootstrap. Demo cluster — broadening kubeconfig
# perms is acceptable. For prod, switch to a system-location kubeconfig at
# /etc/whisperops/kubeconfig.
chmod 755 /root /root/.kube
chmod 644 /root/.kube/config

# 6. Wait gate — poll until every ArgoCD app reports Synced AND Healthy.
#    Surfaces upstream bootstrap failures (e.g. Keycloak config job
#    crashing) loudly instead of letting the operator discover them
#    later via "Backstage 404".
log "Waiting up to ${PLATFORM_READY_TIMEOUT}s for all ArgoCD apps to become Synced/Healthy"
START=$(date +%s)
KUBECONFIG=/root/.kube/config
while true; do
  ELAPSED=$(($(date +%s) - START))
  if [ "${ELAPSED}" -gt "${PLATFORM_READY_TIMEOUT}" ]; then
    log "TIMEOUT: platform did not become ready in ${PLATFORM_READY_TIMEOUT}s"
    log "Final state:"
    /usr/local/bin/kubectl --kubeconfig="${KUBECONFIG}" get apps -A 2>&1 | tee -a "${LOGFILE}"
    exit 1
  fi

  # Apps controller may not exist yet right after idpbuilder create — tolerate that
  STATUS_JSON=$(/usr/local/bin/kubectl --kubeconfig="${KUBECONFIG}" get apps -A -o json 2>/dev/null || echo '{"items":[]}')
  TOTAL=$(echo "${STATUS_JSON}" | jq '.items | length')

  if [ "${TOTAL}" -eq 0 ]; then
    log "  no ArgoCD apps registered yet — waiting (${ELAPSED}s)"
    sleep 15
    continue
  fi

  NOT_READY=$(echo "${STATUS_JSON}" | jq -r '.items[] | select((.status.sync.status != "Synced") or (.status.health.status != "Healthy")) | "\(.metadata.name)[\(.status.sync.status // "?")/\(.status.health.status // "?")]"' | tr '\n' ' ')

  if [ -z "${NOT_READY}" ]; then
    log "All ${TOTAL} ArgoCD apps Synced/Healthy"
    break
  fi

  log "  waiting (${ELAPSED}s) — not ready: ${NOT_READY}"
  sleep 15
done

log "whisperops bootstrap complete"
