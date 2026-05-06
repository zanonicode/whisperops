#!/usr/bin/env bash
# DD-36 (DESIGN v1.10): Rewrite all cnoe.localtest.me host references in
# platform/idp/backstage/manifests/install.yaml to sslip.io URLs derived from
# the VM's external IP. Ordered multi-pass: path-suffixed patterns matched
# before bare domain to prevent double-substitution. Called by _vm-bootstrap
# before helmfile apply. Ref: .claude/sdd/features/DESIGN_whisperops.md §3 DD-36
# DD-38 interaction: this script remains useful even though the operator
# now accesses Backstage via SSH tunnel + cnoe.localtest.me path-routing.
# It still rewrites Backstage's external sslip.io URLs for cases where
# operators use the sslip.io endpoints to view Backstage UI without
# triggering OIDC login (e.g., catalog browsing, quick checks). The
# Keycloak OIDC popup will fail on those sslip.io URLs (redirect_uri
# mismatch); use the tunnel + cnoe.localtest.me path for full OIDC flow.
# See DESIGN §3 DD-38 for the full rationale.
set -euo pipefail

VM_IP="${1:-}"

if [[ -z "$VM_IP" ]] || [[ ! "$VM_IP" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
  echo "ERROR: usage: $0 <VM_IP>  (must be a dotted IPv4 address)" >&2
  exit 1
fi

INSTALL_YAML="$(cd "$(dirname "$0")/../.." && pwd)/platform/idp/backstage/manifests/install.yaml"

if [[ ! -f "$INSTALL_YAML" ]]; then
  echo "ERROR: file not found: $INSTALL_YAML" >&2
  exit 1
fi

# Count occurrences before rewriting (for idempotency reporting).
BEFORE=$(grep -o 'cnoe\.localtest\.me' "$INSTALL_YAML" | wc -l | tr -d ' ')

# Pass 1: cnoe.localtest.me:8443/gitea → gitea.<IP>.sslip.io:8443
sed -i.bak "s|cnoe\.localtest\.me:8443/gitea|gitea.${VM_IP}.sslip.io:8443|g" "$INSTALL_YAML" && rm -f "${INSTALL_YAML}.bak"

# Pass 2: cnoe.localtest.me:8443/argocd → argocd.<IP>.sslip.io:8443
sed -i.bak "s|cnoe\.localtest\.me:8443/argocd|argocd.${VM_IP}.sslip.io:8443|g" "$INSTALL_YAML" && rm -f "${INSTALL_YAML}.bak"

# Pass 3: cnoe.localtest.me:8443/backstage → backstage.<IP>.sslip.io:8443
sed -i.bak "s|cnoe\.localtest\.me:8443/backstage|backstage.${VM_IP}.sslip.io:8443|g" "$INSTALL_YAML" && rm -f "${INSTALL_YAML}.bak"

# Pass 4: cnoe.localtest.me:8443 (remaining bare with port) → backstage.<IP>.sslip.io:8443
sed -i.bak "s|cnoe\.localtest\.me:8443|backstage.${VM_IP}.sslip.io:8443|g" "$INSTALL_YAML" && rm -f "${INSTALL_YAML}.bak"

# Pass 5: cnoe.localtest.me/gitea (no port) → gitea.<IP>.sslip.io:8443
sed -i.bak "s|cnoe\.localtest\.me/gitea|gitea.${VM_IP}.sslip.io:8443|g" "$INSTALL_YAML" && rm -f "${INSTALL_YAML}.bak"

# Pass 6: cnoe.localtest.me (remaining bare) → backstage.<IP>.sslip.io:8443
sed -i.bak "s|cnoe\.localtest\.me|backstage.${VM_IP}.sslip.io:8443|g" "$INSTALL_YAML" && rm -f "${INSTALL_YAML}.bak"

AFTER=$(grep -o 'cnoe\.localtest\.me' "$INSTALL_YAML" | wc -l | tr -d ' ')
N=$(( BEFORE - AFTER ))

echo "Rewrote ${N} occurrences in install.yaml"
