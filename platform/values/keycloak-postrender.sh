#!/usr/bin/env bash
# DISABLED — preserved for a future cutover to a custom Backstage image with a
# guest auth provider. Currently NOT invoked from _vm-bootstrap because
# Keycloak must stay at replicas=1 for OIDC login to work via SSH tunnel +
# CNOE path-routing. Re-enable this script (uncomment its invocation in
# Makefile _vm-bootstrap) only when the custom Backstage image lands.
#
# When invoked, scales the CNOE-managed Keycloak Deployment to zero replicas.
# Not wired into helmfile (Keycloak is an idpbuilder-managed resource, not a
# helmfile release) — provided as a stand-alone patching tool that
# _vm-bootstrap can call after helmfile apply completes.
#
# Usage: kubectl apply -f platform/idp/keycloak/manifests/install.yaml
#        then: bash platform/values/keycloak-postrender.sh
# Idempotent: patching to replicas=0 is a no-op when already 0.
set -euo pipefail

kubectl patch deployment keycloak -n keycloak \
  --type='json' \
  -p='[{"op":"replace","path":"/spec/replicas","value":0}]' \
  2>/dev/null \
  || echo "  ↳ Keycloak Deployment not found or already patched — skipping"

echo "  ✓ Keycloak scaled to 0 replicas"
