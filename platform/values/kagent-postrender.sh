#!/usr/bin/env bash
# kagent postRenderer — injects the Vertex SA-key volume + mount into the
# kagent Deployment and restores the kagent UI nginx proxy_read_timeout: 600s.
#
# Reads helm-rendered multi-doc YAML from stdin (via temp file — direct
# heredoc redirection consumes stdin before python can read it, producing
# an empty render and a silent helmfile "deployed" with zero pods).
# Writes patched output to stdout. Idempotent.
#
# Uses ruamel.yaml (round-trip parser) — NEVER raw sed/regex (the prior
# approach produced invalid YAML; see CLAUDE.md gotcha #9 for context).
#
# Mutations performed:
#   1. kagent Deployment (name=kagent):
#      a. volumes[]   — append vertex-sa-key Secret volume (if not present)
#      b. containers[name=app].volumeMounts[] — append mount at
#         /var/secrets/google (if not present)
#   2. kagent Deployment (name=kagent):
#      Nginx ui container proxy_read_timeout — handled separately via
#      the kagent-nginx-timeout ConfigMap volume (injected in item 1a too).
set -euo pipefail

TMPF=$(mktemp -t kagent-postrender.XXXXXX)
trap 'rm -f "$TMPF"' EXIT
cat > "$TMPF"

python3 - "$TMPF" <<'PY'
import sys
import io
from ruamel.yaml import YAML

yaml = YAML(typ="rt")
yaml.preserve_quotes = True
yaml.indent(mapping=2, sequence=4, offset=2)

src = open(sys.argv[1]).read()
docs = list(yaml.load_all(src))

for d in docs:
    if not d:
        continue
    if d.get("kind") != "Deployment":
        continue
    if d.get("metadata", {}).get("name") != "kagent":
        continue

    spec = d["spec"]["template"]["spec"]

    # ── 1a: volumes ──────────────────────────────────────────────────────────
    vols = spec.setdefault("volumes", [])
    if not any(v.get("name") == "vertex-sa-key" for v in vols):
        vols.append({
            "name": "vertex-sa-key",
            "secret": {
                "secretName": "kagent-vertex-credentials",
                "defaultMode": 0o400,
            },
        })

    # ── 1b: ui nginx ConfigMap volume (restores proxy_read_timeout: 600s) ────
    if not any(v.get("name") == "kagent-nginx-timeout" for v in vols):
        vols.append({
            "name": "kagent-nginx-timeout",
            "configMap": {
                "defaultMode": 420,
                "name": "kagent-nginx-timeout",
            },
        })

    # ── 2: per-container volumeMounts ─────────────────────────────────────────
    for c in spec.get("containers", []):
        name = c.get("name", "")

        if name == "app":
            mounts = c.setdefault("volumeMounts", [])
            if not any(m.get("name") == "vertex-sa-key" for m in mounts):
                mounts.append({
                    "name": "vertex-sa-key",
                    "mountPath": "/var/secrets/google",
                    "readOnly": True,
                })

        if name == "ui":
            mounts = c.setdefault("volumeMounts", [])
            if not any(m.get("mountPath") == "/etc/nginx/nginx.conf" for m in mounts):
                mounts.append({
                    "name": "kagent-nginx-timeout",
                    "mountPath": "/etc/nginx/nginx.conf",
                    "subPath": "nginx.conf",
                    "readOnly": True,
                })

buf = io.StringIO()
yaml.dump_all(docs, buf)
sys.stdout.write(buf.getvalue())
PY
