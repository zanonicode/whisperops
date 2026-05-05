#!/usr/bin/env bash
set -euo pipefail

LOGFILE="/var/log/whisperops-bootstrap.log"
IDPBUILDER_VERSION="v0.10.2"
IDPBUILDER_ARCH="linux-amd64"

log() {
  echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*" | tee -a "${LOGFILE}"
}

log "Starting whisperops bootstrap"

# 1. System packages
log "Installing system packages"
apt-get update -qq
apt-get install -y docker.io git curl

# 2. Docker
log "Enabling Docker"
systemctl enable --now docker

# 3a. kubectl (idpbuilder ships kind but not kubectl, and we need it for ops)
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

# 4. Bootstrap the in-cluster IDP
log "Running idpbuilder create"
idpbuilder create --use-path-routing
log "idpbuilder create completed"

# 5. Distribute kubeconfig to ubuntu user
log "Distributing kubeconfig to ubuntu user"
mkdir -p /home/ubuntu/.kube
cp /root/.kube/config /home/ubuntu/.kube/config
chown ubuntu:ubuntu /home/ubuntu/.kube/config
chmod 600 /home/ubuntu/.kube/config

log "whisperops bootstrap complete"
