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

# Past incident (2026-05-08 chained make deploy): when build-images runs straight
# after copy-repo in the rolled-up `make deploy` target, the VM's startup-script
# may still be installing+starting docker. SSH:22 is ready in 2-3s but dockerd
# socket appears 30-60s later (after `apt install docker.io && systemctl start
# docker`). Without this poll, all builds fail with
#   "dial unix /var/run/docker.sock: connect: no such file or directory"
# Wait up to 5 min for `docker info` to succeed before proceeding.
echo "  ↳ Waiting for Docker daemon (up to 5 min)"
for i in $(seq 1 60); do
    if sudo docker info >/dev/null 2>&1; then
        echo "  ✓ Docker daemon ready"
        break
    fi
    if [ "$i" = "60" ]; then echo "  ✗ Docker daemon not ready after 5 min"; exit 1; fi
    printf "."
    sleep 5
done

sudo gcloud auth configure-docker "${REGISTRY_REGION}-docker.pkg.dev" --quiet

# Each entry: "image-name:dockerfile-path:build-context-path"
# All paths relative to REPO_ROOT.
IMAGES=(
    "budget-controller:src/budget-controller/Dockerfile:src/budget-controller"
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

    if sudo docker build \
        -t "${TAG_LATEST}" \
        -t "${TAG_SHA}" \
        -f "${DOCKERFILE_ABS}" \
        "${BUILD_CONTEXT_ABS}" 2>&1; then
        sudo docker push "${TAG_LATEST}" 2>&1
        sudo docker push "${TAG_SHA}" 2>&1
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
