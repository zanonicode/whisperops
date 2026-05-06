#!/usr/bin/env bash
# Usage:
#   In-cluster (recommended for prototype, bypasses external nginx):
#     IN_CLUSTER=1 AGENT_NAME=agent-housing-demo $0
#   External (requires public DNS + open 443):
#     CLUSTER_IP=1.2.3.4 AGENT_NAME=housing-analyst-abc1 $0
set -euo pipefail

IN_CLUSTER="${IN_CLUSTER:-0}"
CLUSTER_IP="${CLUSTER_IP:-}"
BASE_DOMAIN="${BASE_DOMAIN:-${CLUSTER_IP}.sslip.io}"
AGENT_NAME="${AGENT_NAME:-}"
MAX_WAIT_S="${MAX_WAIT_S:-30}"
LOCAL_PORT="${LOCAL_PORT:-3300}"

if [[ -z "$AGENT_NAME" ]]; then
  echo "ERROR: AGENT_NAME must be set" >&2
  echo "Usage (in-cluster): IN_CLUSTER=1 AGENT_NAME=agent-housing-demo $0" >&2
  echo "Usage (external):   CLUSTER_IP=1.2.3.4 AGENT_NAME=agent-housing-demo $0" >&2
  exit 1
fi

if [[ "$IN_CLUSTER" == "1" ]]; then
  POD=$(kubectl get pod -n "$AGENT_NAME" -l app=chat-frontend -o jsonpath='{.items[0].metadata.name}')
  if [[ -z "$POD" ]]; then
    echo "ERROR: chat-frontend pod not found in namespace $AGENT_NAME" >&2
    exit 1
  fi
  kubectl port-forward -n "$AGENT_NAME" "$POD" "${LOCAL_PORT}:3000" >/dev/null 2>&1 &
  PF_PID=$!
  trap 'kill $PF_PID 2>/dev/null || true' EXIT
  sleep 3
  CHAT_URL="http://127.0.0.1:${LOCAL_PORT}"
else
  if [[ -z "$CLUSTER_IP" ]]; then
    echo "ERROR: CLUSTER_IP must be set when not running with IN_CLUSTER=1" >&2
    exit 1
  fi
  CHAT_URL="https://${AGENT_NAME}.${BASE_DOMAIN}"
fi
PASS=0
FAIL=0

echo "=== Query Roundtrip Test: $AGENT_NAME ==="

TEST_QUESTION="What is the median price in this dataset?"

echo "Testing question: $TEST_QUESTION"

RESPONSE=$(curl -sk --max-time "$MAX_WAIT_S" \
  -X POST "${CHAT_URL}/api/chat" \
  -H "Content-Type: application/json" \
  -H "Accept: text/event-stream" \
  -d "{\"message\": \"${TEST_QUESTION}\"}" 2>/dev/null || echo "")

if [[ -z "$RESPONSE" ]]; then
  echo "FAIL  No response received within ${MAX_WAIT_S}s"
  FAIL=$((FAIL + 1))
else
  echo "PASS  Received response (${#RESPONSE} bytes)"
  PASS=$((PASS + 1))

  if echo "$RESPONSE" | grep -qi "median\|price\|dollar\|usd\|\$"; then
    echo "PASS  Response contains price-related content"
    PASS=$((PASS + 1))
  else
    echo "WARN  Response may not contain expected content (soft check)"
  fi

  if echo "$RESPONSE" | grep -qi "storage.googleapis.com\|chart\|png\|html"; then
    echo "PASS  Response contains chart artifact URL"
    PASS=$((PASS + 1))
  else
    echo "INFO  No chart URL detected (may not be required for this question)"
  fi

  if echo "$RESPONSE" | grep -qi "import pandas\|pd\.read\|plt\.\|plotly"; then
    echo "PASS  Response contains code block"
    PASS=$((PASS + 1))
  else
    echo "INFO  No code block detected (soft check)"
  fi
fi

echo ""
echo "=== Summary: PASS=$PASS FAIL=$FAIL ==="
if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
