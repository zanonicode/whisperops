#!/usr/bin/env bash
set -euo pipefail

CLUSTER_IP="${CLUSTER_IP:-}"
BASE_DOMAIN="${BASE_DOMAIN:-${CLUSTER_IP}.sslip.io}"
BACKSTAGE_TOKEN="${BACKSTAGE_TOKEN:-}"
MAX_WAIT_S="${MAX_WAIT_S:-90}"

if [[ -z "$CLUSTER_IP" ]]; then
  echo "ERROR: CLUSTER_IP must be set" >&2
  exit 1
fi

BACKSTAGE_URL="https://backstage.${BASE_DOMAIN}"
TEST_AGENT_NAME="smoke-test-agent"

echo "=== Backstage Template Submission ==="
SUBMIT_PAYLOAD=$(cat <<EOF
{
  "templateRef": "template:default/dataset-whisperer",
  "values": {
    "agent_name": "${TEST_AGENT_NAME}",
    "description": "Automated smoke test agent",
    "dataset_id": "california-housing",
    "primary_model": "claude-haiku-4-5-20251001",
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
AGENT_NS=$(kubectl get namespace -l "whisperops.io/agent-name=${TEST_AGENT_NAME}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
DEADLINE=$((SECONDS + MAX_WAIT_S))

while [[ $SECONDS -lt $DEADLINE ]]; do
  if [[ -z "$AGENT_NS" ]]; then
    AGENT_NS=$(kubectl get namespace -l "whisperops.io/agent-name=${TEST_AGENT_NAME}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
  fi
  if [[ -n "$AGENT_NS" ]]; then
    AGENT_COUNT=$(kubectl get agents.kagent.dev -n "$AGENT_NS" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$AGENT_COUNT" -ge 3 ]]; then
      echo "PASS  Agent namespace $AGENT_NS has $AGENT_COUNT Agent CRDs"
      break
    fi
  fi
  sleep 5
done

if [[ -z "$AGENT_NS" ]]; then
  echo "FAIL  Agent namespace never appeared within ${MAX_WAIT_S}s"
  exit 1
fi

echo "=== Agent reachability ==="
INGRESS_HOST="${TEST_AGENT_NAME}.${BASE_DOMAIN}"
STATUS=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 "https://${INGRESS_HOST}/" 2>/dev/null || echo "000")
if [[ "$STATUS" == "200" ]]; then
  echo "PASS  Chat UI reachable at https://${INGRESS_HOST}/"
else
  echo "FAIL  Chat UI at https://${INGRESS_HOST}/ returned $STATUS"
  exit 1
fi

echo ""
echo "=== Agent Creation Smoke Test: PASSED ==="
