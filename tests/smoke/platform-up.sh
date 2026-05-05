#!/usr/bin/env bash
set -euo pipefail

CLUSTER_IP="${CLUSTER_IP:-}"
BASE_DOMAIN="${BASE_DOMAIN:-${CLUSTER_IP}.sslip.io}"

if [[ -z "$CLUSTER_IP" ]]; then
  echo "ERROR: CLUSTER_IP must be set to the VM's external IP" >&2
  exit 1
fi

ARGOCD_URL="https://argocd.${BASE_DOMAIN}"
BACKSTAGE_URL="https://backstage.${BASE_DOMAIN}"
GITEA_URL="https://gitea.${BASE_DOMAIN}"
KEYCLOAK_URL="https://keycloak.${BASE_DOMAIN}"
GRAFANA_URL="https://grafana.${BASE_DOMAIN}"

PASS=0
FAIL=0

check_url() {
  local name="$1"
  local url="$2"
  local expected_status="${3:-200}"
  local status
  status=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 "$url" 2>/dev/null || echo "000")
  if [[ "$status" == "$expected_status" ]]; then
    echo "PASS  $name ($url) → $status"
    ((PASS++))
  else
    echo "FAIL  $name ($url) → expected $expected_status, got $status"
    ((FAIL++))
  fi
}

check_argocd_app() {
  local app="$1"
  local sync_status
  sync_status=$(kubectl get application "$app" -n argocd -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "Unknown")
  local health_status
  health_status=$(kubectl get application "$app" -n argocd -o jsonpath='{.status.health.status}' 2>/dev/null || echo "Unknown")
  if [[ "$sync_status" == "Synced" && "$health_status" == "Healthy" ]]; then
    echo "PASS  ArgoCD app '$app' is Synced/Healthy"
    ((PASS++))
  else
    echo "FAIL  ArgoCD app '$app' is $sync_status/$health_status"
    ((FAIL++))
  fi
}

echo "=== Platform Surface Checks ==="
check_url "ArgoCD" "$ARGOCD_URL" "200"
check_url "Backstage" "$BACKSTAGE_URL" "200"
check_url "Gitea" "$GITEA_URL" "200"
check_url "Keycloak" "$KEYCLOAK_URL" "200"
check_url "Grafana" "$GRAFANA_URL" "200"

echo ""
echo "=== ArgoCD Application Health ==="
for app in kagent observability-extras crossplane-providers kyverno-policies sandbox agent-prompts budget-controller platform-bootstrap-job; do
  check_argocd_app "$app"
done

echo ""
echo "=== Crossplane Provider Health ==="
PROVIDER_STATUS=$(kubectl get provider.pkg.crossplane.io provider-gcp -o jsonpath='{.status.conditions[?(@.type=="Healthy")].status}' 2>/dev/null || echo "Unknown")
if [[ "$PROVIDER_STATUS" == "True" ]]; then
  echo "PASS  provider-gcp is Healthy"
  ((PASS++))
else
  echo "FAIL  provider-gcp health: $PROVIDER_STATUS"
  ((FAIL++))
fi

echo ""
echo "=== Summary ==="
echo "PASS: $PASS  FAIL: $FAIL"
if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
