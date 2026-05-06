#!/usr/bin/env bash
# DD-31 (DESIGN v1.7): kagent v0.4.3 chart hardcodes
#   AUTOGEN_DISABLE_RUNTIME_TRACING=true
# in the `app` container's static env list, BEFORE the user-supplied
# `app.env`. We add `=false` via app.env in kagent-values.yaml; rendered
# manifests therefore contain TWO entries with the same name. kubelet
# implements "last wins" so things work, but defense-in-depth: this
# postRender script strips the chart-default `=true` entry so the final
# manifest has exactly ONE `AUTOGEN_DISABLE_RUNTIME_TRACING` env var.
#
# Wired into helmfile via `releases[name=kagent].transformers` or
# `postRender:` (helmfile v0.158+). Reads helm-rendered manifests from
# stdin, writes the patched output to stdout. Idempotent.
set -euo pipefail
exec yq eval '
  (.spec.template.spec.containers[]
    | select(.name == "app")
    | .env)
  |= ([.[] | select(.name != "AUTOGEN_DISABLE_RUNTIME_TRACING")]
      + [.[] | select(.name == "AUTOGEN_DISABLE_RUNTIME_TRACING")][-1:])
' -
