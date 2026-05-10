#!/usr/bin/env bash
# Push the whisperops monorepo snapshot to in-cluster Gitea, then apply the
# ArgoCD root-app (app-of-apps).
#
# Runs INSIDE the VM. Called by `make _push-whisperops-to-gitea` at the end of
# `make _vm-bootstrap`. Idempotent — re-running on existing org/repo succeeds.
#
# Why a separate script instead of an inline Makefile recipe:
#   The original recipe was a 60-line `bash -c '...'` with multiple `'\''`
#   JSON-escape patterns. /bin/sh's quote-state tracking lost balance on
#   line 53 (the `git remote add gitea-push "${PUSH_REMOTE}"` line) and
#   exited with "Unterminated quoted string" — preventing the entire push
#   on first true-clean deploys. Extracting eliminates the make → sh → bash
#   quote-nesting interaction.

set -euo pipefail

REPO_DIR=/tmp/whisperops
GITEA_PORT=13001
GITEA_HOST=127.0.0.1

export KUBECONFIG=/root/.kube/config

cd "${REPO_DIR}"

echo "  ↳ Resolving Gitea admin password"
GITEA_PASS=$(kubectl get secret -n gitea gitea-credential -o jsonpath='{.data.password}' | base64 -d)

echo "  ↳ Port-forwarding Gitea on ${GITEA_PORT}:3000"
kubectl port-forward -n gitea svc/my-gitea-http "${GITEA_PORT}:3000" >/dev/null 2>&1 &
PF_PID=$!
trap 'kill ${PF_PID} 2>/dev/null || true' EXIT INT TERM
sleep 3

GITEA_URL="http://${GITEA_HOST}:${GITEA_PORT}"
GITEA_AUTH="giteaAdmin:${GITEA_PASS}"

echo "  ↳ Creating Gitea org 'whisperops' (idempotent)"
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST "${GITEA_URL}/api/v1/orgs" \
    -H "Content-Type: application/json" \
    -u "${GITEA_AUTH}" \
    -d '{"username":"whisperops","visibility":"public"}')
case "${HTTP_CODE}" in
    201) echo "  ✓ Org whisperops created" ;;
    422) echo "  ↳ Org whisperops already exists — skipping" ;;
    *)   echo "  ✗ Org creation returned HTTP ${HTTP_CODE} — aborting"; exit 1 ;;
esac

echo "  ↳ Creating Gitea repo 'whisperops/whisperops' (idempotent)"
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST "${GITEA_URL}/api/v1/orgs/whisperops/repos" \
    -H "Content-Type: application/json" \
    -u "${GITEA_AUTH}" \
    -d '{"name":"whisperops","private":false,"auto_init":true,"default_branch":"main"}')
case "${HTTP_CODE}" in
    201) echo "  ✓ Repo whisperops/whisperops created" ;;
    409) echo "  ↳ Repo whisperops/whisperops already exists — skipping creation" ;;
    *)   echo "  ✗ Repo creation returned HTTP ${HTTP_CODE} — aborting"; exit 1 ;;
esac

echo "  ↳ Pushing ${REPO_DIR} to gitea whisperops/whisperops"
# URL-encode Gitea password via jq @uri: the admin password contains
# URL-reserved characters; embedding it raw breaks git's URL parser.
GITEA_PASS_ENC=$(printf %s "${GITEA_PASS}" | jq -sRr @uri)
PUSH_REMOTE="http://giteaAdmin:${GITEA_PASS_ENC}@${GITEA_HOST}:${GITEA_PORT}/whisperops/whisperops.git"

# /tmp/whisperops has no .git/ (copy-repo excludes it). Create a fresh
# snapshot repo here so we can push to Gitea. ArgoCD only needs HEAD content,
# not history. This is destructive on /tmp/whisperops/.git but that dir is
# transient (rebuilt every copy-repo run).
rm -rf "${REPO_DIR}/.git"
git -C "${REPO_DIR}" init -q -b main
git -C "${REPO_DIR}" -c user.email=ci@whisperops.io -c user.name=whisperops-ci add -A
git -C "${REPO_DIR}" -c user.email=ci@whisperops.io -c user.name=whisperops-ci \
    commit -q -m "whisperops snapshot for ArgoCD reconciliation"
git -C "${REPO_DIR}" remote add gitea-push "${PUSH_REMOTE}"
git -C "${REPO_DIR}" push gitea-push main:main --force 2>&1 | tail -5
git -C "${REPO_DIR}" remote remove gitea-push 2>/dev/null || true
echo "  ✓ Repo snapshot pushed to Gitea"

echo "  ↳ Applying ArgoCD root-app (app-of-apps)"
kubectl apply -f "${REPO_DIR}/platform/argocd/bootstrap/root-app.yaml"
echo "  ✓ root-app applied — ArgoCD will register 8 child apps and sync from whisperops/whisperops.git"
echo "  Note: initial sync may take 2-5 min; check with: kubectl get app -n argocd"
