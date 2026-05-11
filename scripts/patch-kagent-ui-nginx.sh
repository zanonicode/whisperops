#!/usr/bin/env bash
# Patch the kagent Deployment to mount the kagent-nginx-timeout ConfigMap
# onto the `ui` container at /etc/nginx/nginx.conf.
#
# WHY:
#   The kagent chart's `ui` container runs nginx with a baked-in nginx.conf
#   whose /api/ location block inherits the nginx default proxy_read_timeout
#   of 60s. Heavy agent queries (write Python → exec → chart → synthesise)
#   accumulate >60s wall-time, causing the nginx layer to terminate the
#   upstream connection with HTTP 504. The chart exposes no ui.nginx.* keys
#   and no extraNginxConfig injection point.
#
# Replaces the disabled kagent-postrender.sh (regex approach was fragile and
# produced invalid YAML on edge cases — see PENDING.B8). Runs INSIDE the VM
# from `_vm-bootstrap` after helmfile-apply.
#
# Idempotent: if the volume + volumeMount are already present from a prior
# run, the script no-ops without touching the Deployment.
#
# Container-index discovery is dynamic (`jq` finds 'ui' by name) so chart
# version bumps that reorder containers don't break the patch.

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

# Detect whether ui container's volumeMounts array already exists. JSON patch
# `op: add` with `/-` requires the parent array to exist; if absent we must
# create the whole array at once. The idempotency guard above means we only
# ever reach this code when the volume hasn't been added yet, but volumeMounts
# may or may not exist depending on whether the chart sets any defaults.
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

# RFC 6902 JSON patch. Two ops:
#   1. Append the kagent-nginx-timeout volume to spec.template.spec.volumes
#      (volumes array always exists — the chart populates `sqlite-volume`).
#   2. Add or append the volumeMount to the ui container (depends on array
#      existence detected above).
# Strategic merge would be simpler but per CLAUDE.md Workflow Rule #6 it
# can silently truncate sibling array entries — JSON patch is robust.
kubectl patch deploy "${DEPLOY}" -n "${NAMESPACE}" --type=json -p="[
  {\"op\":\"add\",\"path\":\"/spec/template/spec/volumes/-\",
   \"value\":{\"name\":\"${VOLUME_NAME}\",
              \"configMap\":{\"name\":\"${VOLUME_NAME}\",\"defaultMode\":420}}},
  {\"op\":\"${UI_VM_OP}\",\"path\":\"${UI_VM_PATH}\",\"value\":${UI_VM_VALUE}}
]" >/dev/null

echo "  ✓ ${VOLUME_NAME} mounted on ${DEPLOY} ui container — Deployment will roll new ReplicaSet"
echo "    /api/ and /api/ws/ proxy_read_timeout now 600s (was 60s default)"
