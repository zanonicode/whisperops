#!/usr/bin/env bash
set -euo pipefail

CLUSTER_IP="${CLUSTER_IP:-}"
BASE_DOMAIN="${BASE_DOMAIN:-${CLUSTER_IP}.sslip.io}"
AGENT_NAME="${AGENT_NAME:-}"
MAX_WAIT_S="${MAX_WAIT_S:-30}"

if [[ -z "$CLUSTER_IP" || -z "$AGENT_NAME" ]]; then
  echo "ERROR: CLUSTER_IP and AGENT_NAME must be set" >&2
  echo "Usage: CLUSTER_IP=1.2.3.4 AGENT_NAME=housing-analyst-abc1 $0" >&2
  exit 1
fi

CHAT_URL="https://${AGENT_NAME}.${BASE_DOMAIN}"
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
  ((FAIL++))
else
  echo "PASS  Received response (${#RESPONSE} bytes)"
  ((PASS++))

  if echo "$RESPONSE" | grep -qi "median\|price\|dollar\|usd\|\$"; then
    echo "PASS  Response contains price-related content"
    ((PASS++))
  else
    echo "WARN  Response may not contain expected content (soft check)"
  fi

  if echo "$RESPONSE" | grep -qi "storage.googleapis.com\|chart\|png\|html"; then
    echo "PASS  Response contains chart artifact URL"
    ((PASS++))
  else
    echo "INFO  No chart URL detected (may not be required for this question)"
  fi

  if echo "$RESPONSE" | grep -qi "import pandas\|pd\.read\|plt\.\|plotly"; then
    echo "PASS  Response contains code block"
    ((PASS++))
  else
    echo "INFO  No code block detected (soft check)"
  fi
fi

echo ""
echo "=== Summary: PASS=$PASS FAIL=$FAIL ==="
if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
