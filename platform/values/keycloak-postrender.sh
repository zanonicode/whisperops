#!/usr/bin/env bash
# DD-33 (DESIGN v1.10): Scale the CNOE Keycloak Deployment to zero replicas.
# Keycloak OIDC is disabled in favour of Backstage guest auth (DD-33).
# This postRender hook is not wired into helmfile (Keycloak is an idpbuilder
# managed resource, not a helmfile release) — it is provided as a stand-alone
# patching tool invoked by _vm-bootstrap after helmfile apply completes.
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

echo "  ✓ Keycloak scaled to 0 replicas (DD-33)"
