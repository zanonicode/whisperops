#!/usr/bin/env bash
# Print all whisperops platform endpoints + credentials.
#
# Runs on the operator machine. Fetches VM_IP via gcloud, then SSHes once
# to the VM to pull all relevant K8s Secret values in a single round-trip.
#
# Invoked as the final step of `make deploy` and standalone via `make endpoints`
# whenever the operator needs to recall credentials. Each VM IP changes per
# deploy (no static reservation), so URLs must be re-fetched each cycle.
#
# Missing secrets render as "(not ready)" so partial-deploy states still print
# something useful instead of dying with empty values.

set -euo pipefail

ZONE="${ZONE:-us-central1-a}"

VM_IP=$(gcloud compute instances describe whisperops-vm --zone="${ZONE}" \
    --format='value(networkInterfaces[0].accessConfigs[0].natIP)' 2>/dev/null || true)

if [ -z "${VM_IP}" ]; then
    echo "ERROR: whisperops-vm not running. Run \`make deploy\` first." >&2
    exit 1
fi

# Single SSH round-trip — avoids 5+ separate connection setups.
# Output is one KEY=VALUE per line; empty values become "(not ready)" below.
CREDS=$(gcloud compute ssh whisperops-vm --zone="${ZONE}" \
    --ssh-flag="-o ServerAliveInterval=30" \
    --ssh-flag="-o ServerAliveCountMax=3" \
    --command='
get_secret() {
    sudo kubectl get secret -n "$1" "$2" -o jsonpath="{.data.$3}" 2>/dev/null \
        | base64 -d 2>/dev/null
}
echo "ARGOCD=$(get_secret argocd argocd-initial-admin-secret password)"
echo "GITEA=$(get_secret gitea gitea-credential password)"
echo "GRAFANA=$(get_secret observability lgtm-distributed-grafana admin-password)"
echo "KEYCLOAK_USER1=$(get_secret keycloak keycloak-config USER_PASSWORD)"
echo "KEYCLOAK_ADMIN=$(get_secret keycloak keycloak-config KEYCLOAK_ADMIN_PASSWORD)"
' 2>/dev/null || true)

# Parse "KEY=VALUE" pairs by splitting on the FIRST = only — passwords often
# contain = and other special chars. Empty values render as "(not ready)".
extract() {
    local key="$1"
    local val
    val=$(printf '%s\n' "${CREDS}" | sed -n "s/^${key}=//p" | head -1)
    if [ -z "${val}" ]; then
        printf '(not ready)'
    else
        printf '%s' "${val}"
    fi
}

ARGOCD=$(extract ARGOCD)
GITEA=$(extract GITEA)
GRAFANA=$(extract GRAFANA)
KEYCLOAK_USER1=$(extract KEYCLOAK_USER1)
KEYCLOAK_ADMIN=$(extract KEYCLOAK_ADMIN)

cat <<EOF

══════════════════════════════════════════════════════════════════════════
  whisperops endpoints + credentials
══════════════════════════════════════════════════════════════════════════

  VM_IP: ${VM_IP}    (changes per deploy — no static IP reservation)

  ── Web UIs (sslip.io — public, self-signed cert, browser will warn) ────
  Backstage           https://backstage.${VM_IP}.sslip.io:8443
                        ↳ login via Keycloak SSO requires SSH tunnel (below)
  ArgoCD              https://argocd.${VM_IP}.sslip.io:8443
                        admin / ${ARGOCD}
  Gitea               https://gitea.${VM_IP}.sslip.io:8443
                        giteaAdmin / ${GITEA}
  Grafana             https://grafana.${VM_IP}.sslip.io:8443
                        admin / ${GRAFANA}

  ── SSH tunnel (required for Backstage SSO + Keycloak admin console) ────
  In another terminal, keep open:
    gcloud compute ssh whisperops-vm --zone=${ZONE} -- -L 8443:127.0.0.1:8443

  Then browse:
    Backstage         https://cnoe.localtest.me:8443/backstage
                        user1 / ${KEYCLOAK_USER1}
    Keycloak admin    https://cnoe.localtest.me:8443/keycloak
                        cnoe-admin / ${KEYCLOAK_ADMIN}

  ── Public (no auth) ────────────────────────────────────────────────────
  Backstage health    https://backstage.${VM_IP}.sslip.io:8443/healthcheck

  ── Internal (port-forward only, no Ingress by design) ──────────────────
  kagent UI           gcloud compute ssh whisperops-vm --zone=${ZONE} \\
                        --command='sudo kubectl -n kagent-system port-forward svc/kagent 8001:80'

  ── External SaaS ───────────────────────────────────────────────────────
  Langfuse            https://us.cloud.langfuse.com
                        env from langfuse-credentials Secret

  ── Per-agent chat URLs (after Backstage scaffold) ───────────────────────
  Pattern: https://chat-<agent-name>.${VM_IP}.sslip.io:8443
  List live:
    gcloud compute ssh whisperops-vm --zone=${ZONE} \\
      --command='sudo kubectl get ingress -A | grep chat-'

══════════════════════════════════════════════════════════════════════════

EOF
