#!/usr/bin/env bash
# DD-38 (v1.12): DISABLED — this script is preserved for future Opção L
# (custom Backstage image with guest auth provider). Currently NOT called
# from _vm-bootstrap because Keycloak must stay at replicas=1 for OIDC
# login to work via SSH tunnel + CNOE path-routing. Re-enable this script
# (uncomment its invocation in Makefile _vm-bootstrap) only when the
# custom Backstage image lands. See DESIGN §3 DD-38 and §15 item #22.
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
