#!/usr/bin/env bash
# Mount the kagent-nginx-timeout ConfigMap onto the kagent ui container at
# /etc/nginx/nginx.conf. Idempotent: no-op if already mounted. Container
# index is discovered dynamically via jq.

set -euo pipefail

REPO_DIR=/tmp/whisperops
NAMESPACE=kagent-system
DEPLOY=kagent
VOLUME_NAME=kagent-nginx-timeout
CONFIGMAP_FILE="${REPO_DIR}/platform/values/kagent-nginx-timeout.yaml"

export KUBECONFIG=/root/.kube/config

echo "  ↳ Applying ${VOLUME_NAME} ConfigMap"
kubectl apply -f "${CONFIGMAP_FILE}" >/dev/null

# Idempotency check: bail early if the volume is already attached.
ALREADY=$(kubectl get deploy "${DEPLOY}" -n "${NAMESPACE}" \
    -o jsonpath="{.spec.template.spec.volumes[?(@.name=='${VOLUME_NAME}')].name}" 2>/dev/null || true)
if [ "${ALREADY}" = "${VOLUME_NAME}" ]; then
    echo "  ↳ ${VOLUME_NAME} already mounted on ${DEPLOY} — no patch needed"
    exit 0
fi

# Find the 'ui' container index dynamically (kagent chart may add/reorder
# containers across version bumps). jq returns the integer index or null.
UI_IDX=$(kubectl get deploy "${DEPLOY}" -n "${NAMESPACE}" -o json \
    | jq '.spec.template.spec.containers | map(.name) | index("ui")')
if [ "${UI_IDX}" = "null" ] || [ -z "${UI_IDX}" ]; then
    echo "  ✗ Could not find 'ui' container in ${DEPLOY} Deployment — bailing" >&2
    exit 1
fi

echo "  ↳ Patching ${DEPLOY} (ui container at index ${UI_IDX})"

# JSON patch `op: add` with `/-` requires the parent array to exist; if
# the ui container has no volumeMounts at all, create the whole array.
HAS_VM=$(kubectl get deploy "${DEPLOY}" -n "${NAMESPACE}" \
    -o jsonpath="{.spec.template.spec.containers[${UI_IDX}].volumeMounts}" 2>/dev/null || true)

if [ -z "${HAS_VM}" ]; then
    # ui container has no volumeMounts at all — create the array with our entry.
    UI_VM_OP="add"
    UI_VM_PATH="/spec/template/spec/containers/${UI_IDX}/volumeMounts"
    UI_VM_VALUE="[{\"name\":\"${VOLUME_NAME}\",\"mountPath\":\"/etc/nginx/nginx.conf\",\"subPath\":\"nginx.conf\",\"readOnly\":true}]"
else
    # volumeMounts exists — append to it.
    UI_VM_OP="add"
    UI_VM_PATH="/spec/template/spec/containers/${UI_IDX}/volumeMounts/-"
    UI_VM_VALUE="{\"name\":\"${VOLUME_NAME}\",\"mountPath\":\"/etc/nginx/nginx.conf\",\"subPath\":\"nginx.conf\",\"readOnly\":true}"
fi

# Strategic merge can silently truncate sibling array entries; use JSON patch.
kubectl patch deploy "${DEPLOY}" -n "${NAMESPACE}" --type=json -p="[
  {\"op\":\"add\",\"path\":\"/spec/template/spec/volumes/-\",
   \"value\":{\"name\":\"${VOLUME_NAME}\",
              \"configMap\":{\"name\":\"${VOLUME_NAME}\",\"defaultMode\":420}}},
  {\"op\":\"${UI_VM_OP}\",\"path\":\"${UI_VM_PATH}\",\"value\":${UI_VM_VALUE}}
]" >/dev/null

echo "  ✓ ${VOLUME_NAME} mounted on ${DEPLOY} ui container — Deployment will roll new ReplicaSet"
echo "    /api/ and /api/ws/ proxy_read_timeout now 600s (was 60s default)"
