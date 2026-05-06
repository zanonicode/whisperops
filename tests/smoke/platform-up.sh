#!/usr/bin/env bash
# Verifies platform-layer health.
# Usage:
#   In-cluster (recommended for prototype, no external HTTPS needed):
#     IN_CLUSTER=1 $0
#   External (requires public DNS + open 443):
#     CLUSTER_IP=1.2.3.4 $0
set -euo pipefail

IN_CLUSTER="${IN_CLUSTER:-0}"
CLUSTER_IP="${CLUSTER_IP:-}"
BASE_DOMAIN="${BASE_DOMAIN:-${CLUSTER_IP}.sslip.io}"

if [[ "$IN_CLUSTER" != "1" && -z "$CLUSTER_IP" ]]; then
  echo "ERROR: set IN_CLUSTER=1 (recommended) or CLUSTER_IP=<vm-ip>" >&2
  exit 1
fi

PASS=0
FAIL=0

check_url() {
  local name="$1"
  local url="$2"
  local expected_status="${3:-200}"
  local status
  status=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 "$url" 2>/dev/null || echo "000")
  if [[ "$status" == "$expected_status" ]]; then
    echo "PASS  $name ($url) -> $status"
    PASS=$((PASS + 1))
  else
    echo "FAIL  $name ($url) -> expected $expected_status, got $status"
    FAIL=$((FAIL + 1))
  fi
}

check_svc_in_cluster() {
  local name="$1"
  local ns="$2"
  local svc="$3"
  local port="$4"
  local path="${5:-/}"
  local expected_status="${6:-200}"
  local pf_port=$((30000 + RANDOM % 20000))
  kubectl port-forward -n "$ns" "svc/$svc" "${pf_port}:${port}" >/dev/null 2>&1 &
  local pid=$!
  sleep 2
  local status
  status=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 "http://127.0.0.1:${pf_port}${path}" 2>/dev/null || echo "000")
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  if [[ "$status" == "$expected_status" ]]; then
    echo "PASS  $name (svc/$svc:$port) -> $status"
    PASS=$((PASS + 1))
  else
    echo "FAIL  $name (svc/$svc:$port) -> expected $expected_status, got $status"
    FAIL=$((FAIL + 1))
  fi
}

check_pods_ready() {
  local label="$1"
  local ns="$2"
  local ready
  ready=$(kubectl get pods -n "$ns" -l "$label" \
    -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null \
    | grep -c "^True$" || true)
  local total
  total=$(kubectl get pods -n "$ns" -l "$label" --no-headers 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$ready" -gt 0 && "$ready" == "$total" ]]; then
    echo "PASS  pods ready: $label in $ns ($ready/$total)"
    PASS=$((PASS + 1))
  else
    echo "FAIL  pods ready: $label in $ns ($ready/$total)"
    FAIL=$((FAIL + 1))
  fi
}

if [[ "$IN_CLUSTER" == "1" ]]; then
  echo "=== Platform Pods Ready ==="
  check_pods_ready "app.kubernetes.io/name=argocd-server" "argocd"
  check_pods_ready "app=backstage" "backstage"
  check_pods_ready "app.kubernetes.io/name=gitea" "gitea"
  check_pods_ready "app=keycloak" "keycloak"
  check_pods_ready "app.kubernetes.io/name=grafana" "observability"
  check_pods_ready "app.kubernetes.io/instance=kagent" "kagent-system"
  check_pods_ready "app.kubernetes.io/name=opentelemetry-collector" "observability"
else
  echo "=== Platform Surface Checks (external) ==="
  check_url "ArgoCD"    "https://argocd.${BASE_DOMAIN}"    "200"
  check_url "Backstage" "https://backstage.${BASE_DOMAIN}" "200"
  check_url "Gitea"     "https://gitea.${BASE_DOMAIN}"     "200"
  check_url "Keycloak"  "https://keycloak.${BASE_DOMAIN}"  "200"
  check_url "Grafana"   "https://grafana.${BASE_DOMAIN}"   "200"
fi

echo ""
echo "=== Crossplane GCP Providers ==="
for prov in provider-gcp-storage provider-gcp-iam provider-gcp-cloudplatform; do
  status=$(kubectl get provider.pkg.crossplane.io "$prov" \
    -o jsonpath='{.status.conditions[?(@.type=="Healthy")].status}' 2>/dev/null || echo "Unknown")
  if [[ "$status" == "True" ]]; then
    echo "PASS  $prov is Healthy"
    PASS=$((PASS + 1))
  else
    echo "FAIL  $prov health: $status"
    FAIL=$((FAIL + 1))
  fi
done

echo ""
echo "=== Summary: PASS=$PASS FAIL=$FAIL ==="
if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
