#!/usr/bin/env bash
# Verifies an agent can be scaffolded by Backstage and reaches Healthy state.
# Usage:
#   In-cluster (uses port-forward to Backstage svc):
#     IN_CLUSTER=1 BACKSTAGE_TOKEN=<token> $0
#   External (requires public DNS + open 443):
#     CLUSTER_IP=1.2.3.4 BACKSTAGE_TOKEN=<token> $0
set -euo pipefail

IN_CLUSTER="${IN_CLUSTER:-0}"
CLUSTER_IP="${CLUSTER_IP:-}"
BASE_DOMAIN="${BASE_DOMAIN:-${CLUSTER_IP}.sslip.io}"
BACKSTAGE_TOKEN="${BACKSTAGE_TOKEN:-}"
MAX_WAIT_S="${MAX_WAIT_S:-180}"
TEST_AGENT_NAME="${TEST_AGENT_NAME:-smoke-test-agent}"
TEST_DATASET="${TEST_DATASET:-california-housing}"

if [[ "$IN_CLUSTER" != "1" && -z "$CLUSTER_IP" ]]; then
  echo "ERROR: set IN_CLUSTER=1 (recommended) or CLUSTER_IP=<vm-ip>" >&2
  exit 1
fi

if [[ -z "$BACKSTAGE_TOKEN" ]]; then
  echo "ERROR: BACKSTAGE_TOKEN must be set (mint via Backstage UI -> User Settings -> Auth Providers)" >&2
  exit 1
fi

if [[ "$IN_CLUSTER" == "1" ]]; then
  PF_PORT=$((30000 + RANDOM % 20000))
  kubectl port-forward -n backstage svc/backstage "${PF_PORT}:80" >/dev/null 2>&1 &
  PF_PID=$!
  trap 'kill $PF_PID 2>/dev/null || true' EXIT
  sleep 3
  BACKSTAGE_URL="http://127.0.0.1:${PF_PORT}"
else
  BACKSTAGE_URL="https://backstage.${BASE_DOMAIN}"
fi

echo "=== Backstage Template Submission ==="
SUBMIT_PAYLOAD=$(cat <<EOF
{
  "templateRef": "template:default/dataset-whisperer",
  "values": {
    "agent_name": "${TEST_AGENT_NAME}",
    "description": "Automated smoke test agent",
    "dataset_id": "${TEST_DATASET}",
    "primary_model": "claude-sonnet-4-5-20250929",
    "budget_usd": "1.00"
  }
}
EOF
)

TASK_ID=$(curl -sk -X POST \
  "${BACKSTAGE_URL}/api/scaffolder/v2/tasks" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${BACKSTAGE_TOKEN}" \
  -d "$SUBMIT_PAYLOAD" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo "")

if [[ -z "$TASK_ID" ]]; then
  echo "FAIL  Could not create scaffolder task"
  exit 1
fi

echo "PASS  Scaffolder task created: $TASK_ID"

echo "=== Waiting for scaffolder task to complete ==="
DEADLINE=$((SECONDS + 60))
while [[ $SECONDS -lt $DEADLINE ]]; do
  STATUS=$(curl -sk "${BACKSTAGE_URL}/api/scaffolder/v2/tasks/${TASK_ID}" \
    -H "Authorization: Bearer ${BACKSTAGE_TOKEN}" | \
    python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || echo "unknown")
  if [[ "$STATUS" == "completed" ]]; then
    echo "PASS  Scaffolder task completed"
    break
  elif [[ "$STATUS" == "failed" ]]; then
    echo "FAIL  Scaffolder task failed"
    exit 1
  fi
  sleep 5
done

echo "=== Waiting for ArgoCD to sync agent (max ${MAX_WAIT_S}s) ==="
AGENT_NS="agent-${TEST_AGENT_NAME}"
DEADLINE=$((SECONDS + MAX_WAIT_S))

while [[ $SECONDS -lt $DEADLINE ]]; do
  if kubectl get namespace "$AGENT_NS" >/dev/null 2>&1; then
    AGENT_COUNT=$(kubectl get agents.kagent.dev -n "$AGENT_NS" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$AGENT_COUNT" -ge 3 ]]; then
      echo "PASS  Agent namespace $AGENT_NS has $AGENT_COUNT Agent CRDs"
      break
    fi
  fi
  sleep 5
done

if ! kubectl get namespace "$AGENT_NS" >/dev/null 2>&1; then
  echo "FAIL  Agent namespace $AGENT_NS never appeared within ${MAX_WAIT_S}s"
  exit 1
fi

echo "=== Chat-frontend pod ready ==="
DEADLINE=$((SECONDS + 60))
READY=0
while [[ $SECONDS -lt $DEADLINE ]]; do
  POD_READY=$(kubectl get pod -n "$AGENT_NS" -l app=chat-frontend \
    -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
  if [[ "$POD_READY" == "True" ]]; then
    READY=1
    break
  fi
  sleep 5
done

if [[ "$READY" == "1" ]]; then
  echo "PASS  Chat-frontend pod is Ready"
else
  echo "FAIL  Chat-frontend pod never became Ready"
  exit 1
fi

echo ""
echo "=== Agent Creation Smoke Test: PASSED ==="
echo "Next: run query-roundtrip.sh with AGENT_NAME=$AGENT_NS"
