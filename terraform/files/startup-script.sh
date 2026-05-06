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
PLATFORM_READY_TIMEOUT=900

log() {
  echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*" | tee -a "${LOGFILE}"
}

log "Starting whisperops bootstrap"

# 1. System packages
log "Installing system packages"
apt-get update -qq
apt-get install -y docker.io git curl jq

# 2. Docker
log "Enabling Docker"
systemctl enable --now docker

# 3a. kubectl (idpbuilder ships kind but not kubectl, and we need it for ops + the wait gate)
log "Installing kubectl"
KUBECTL_VERSION="$(curl -fsSL https://dl.k8s.io/release/stable.txt)"
curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" -o /tmp/kubectl
install -m 0755 /tmp/kubectl /usr/local/bin/kubectl
rm /tmp/kubectl

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
