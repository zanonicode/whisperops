#!/usr/bin/env bash
# Build whisperops-owned container images and push to Artifact Registry.
# Runs INSIDE the VM (linux/amd64 native — no cross-arch friction).
# Invoked by: gcloud compute ssh whisperops-vm --command='cd /tmp/whisperops && bash scripts/build-images.sh'
# Makefile target: make build-images
#
# Prerequisites (all satisfied by the VM bootstrap path):
#   - docker.io installed (startup-script lines 28-33)
#   - gcloud authenticated via metadata-server SA (bootstrap SA holds roles/artifactregistry.writer)
#   - repo available at /tmp/whisperops after make copy-repo
#
# Build-context rules (verified against each Dockerfile):
#   sandbox           — repo root (Dockerfile uses COPY src/sandbox/... paths)
#   budget-controller — src/budget-controller/ (COPY pyproject.toml + main.py)
#   platform-bootstrap — src/platform-bootstrap/ (COPY pyproject.toml + bootstrap.py + profile_schema.py)
#   chat-frontend     — src/chat-frontend/ (COPY package.json then COPY . .)

set -euo pipefail

REPO_ROOT="/tmp/whisperops"
REGISTRY_REGION="us-central1"
PROJECT_ID="$(curl -sf -H "Metadata-Flavor: Google" \
    http://metadata.google.internal/computeMetadata/v1/project/project-id)"
REGISTRY="${REGISTRY_REGION}-docker.pkg.dev/${PROJECT_ID}/whisperops-images"
GIT_SHA="$(git -C "${REPO_ROOT}" rev-parse --short HEAD 2>/dev/null || echo "unknown")"

echo "→ Building whisperops images"
echo "  PROJECT_ID=${PROJECT_ID}"
echo "  REGISTRY=${REGISTRY}"
echo "  GIT_SHA=${GIT_SHA}"

gcloud auth configure-docker "${REGISTRY_REGION}-docker.pkg.dev" --quiet

# Each entry: "image-name:dockerfile-path:build-context-path"
# All paths relative to REPO_ROOT.
IMAGES=(
    "budget-controller:src/budget-controller/Dockerfile:src/budget-controller"
    "platform-bootstrap:src/platform-bootstrap/Dockerfile:src/platform-bootstrap"
    "sandbox:src/sandbox/Dockerfile:."
    "chat-frontend:src/chat-frontend/Dockerfile:src/chat-frontend"
)

FAILED=()

for ENTRY in "${IMAGES[@]}"; do
    NAME="${ENTRY%%:*}"
    REST="${ENTRY#*:}"
    DOCKERFILE_REL="${REST%%:*}"
    BUILD_CONTEXT_REL="${REST#*:}"

    DOCKERFILE_ABS="${REPO_ROOT}/${DOCKERFILE_REL}"
    BUILD_CONTEXT_ABS="${REPO_ROOT}/${BUILD_CONTEXT_REL}"

    if [ ! -f "${DOCKERFILE_ABS}" ]; then
        echo "  ↳ Skipping ${NAME}: Dockerfile not found at ${DOCKERFILE_ABS}"
        continue
    fi

    TAG_LATEST="${REGISTRY}/${NAME}:latest"
    TAG_SHA="${REGISTRY}/${NAME}:${GIT_SHA}"

    echo "  ↳ Building ${NAME} (context=${BUILD_CONTEXT_REL})"

    if docker build \
        -t "${TAG_LATEST}" \
        -t "${TAG_SHA}" \
        -f "${DOCKERFILE_ABS}" \
        "${BUILD_CONTEXT_ABS}" 2>&1; then
        docker push "${TAG_LATEST}" 2>&1
        docker push "${TAG_SHA}" 2>&1
        echo "  ✓ ${NAME} pushed as :latest and :${GIT_SHA}"
    else
        echo "  ✗ ${NAME} build FAILED"
        FAILED+=("${NAME}")
    fi
done

if [ "${#FAILED[@]}" -gt 0 ]; then
    echo "✗ Build failed for: ${FAILED[*]}"
    exit 1
fi

echo "✓ All whisperops images built and pushed to ${REGISTRY}"
