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
# DD-47 (DESIGN v1.20): kagent chart exposes no ui.nginx.* timeout keys
# (Path A/B unavailable). This script also patches the Deployment spec to:
#   1. Add a volume `kagent-nginx-dd47` backed by ConfigMap `kagent-nginx-dd47`
#   2. Mount it on the `ui` container at /etc/nginx/nginx.conf (subPath: nginx.conf)
# The ConfigMap is applied separately (platform/values/kagent-nginx-dd47.yaml).
#
# Uses python3 (not yq) because yq is not available on the target VM.
# Reads helm-rendered multi-doc YAML from stdin, writes patched output to stdout.
# Idempotent.
set -euo pipefail

# Past incident (2026-05-08, DD-71 chase): the previous form was
#   python3 - "$@" <<'PYEOF' ... PYEOF
# but heredoc redirection consumes stdin, leaving nothing for sys.stdin.read()
# to receive. Helm post-renderer protocol pipes the rendered manifest to stdin
# via the bash script's own stdin — so this collision produced an EMPTY
# rendered output (3 lines instead of 3852). Helmfile then installed the
# empty release as "deployed" — kagent had a helm-secret record but zero
# actual resources in the cluster. Fix: write the python script to a temp
# file first; stdin then stays available for the helm-rendered YAML.
TMP_PY=$(mktemp -t kagent-postrender.XXXXXX)
trap 'rm -f "$TMP_PY"' EXIT
cat > "$TMP_PY" <<'PYEOF'
import sys
import re

input_text = sys.stdin.read()

# Split on YAML document separators, preserving the separator with the doc
docs_raw = re.split(r'(?m)^---\s*$', input_text)
out_docs = []

for raw in docs_raw:
    stripped = raw.strip()
    if not stripped:
        out_docs.append(raw)
        continue

    # Only manipulate the Deployment document
    if 'kind: Deployment' not in stripped:
        out_docs.append(raw)
        continue

    # --- DD-31: deduplicate AUTOGEN_DISABLE_RUNTIME_TRACING env var ---
    # Remove the chart-default `=true` entry; keep the user-supplied `=false`
    # The pattern matches the chart-default block:
    #   - name: AUTOGEN_DISABLE_RUNTIME_TRACING
    #     value: "true"
    # We remove duplicate entries keeping only the last occurrence.
    lines = raw.split('\n')
    autogen_indices = []
    for i, line in enumerate(lines):
        if 'AUTOGEN_DISABLE_RUNTIME_TRACING' in line and i + 1 < len(lines):
            autogen_indices.append(i)

    if len(autogen_indices) > 1:
        # Keep last occurrence; remove all prior ones (plus their value: line)
        to_remove = set()
        for idx in autogen_indices[:-1]:
            to_remove.add(idx)
            if idx + 1 < len(lines) and 'value:' in lines[idx + 1]:
                to_remove.add(idx + 1)
        lines = [l for i, l in enumerate(lines) if i not in to_remove]
        raw = '\n'.join(lines)

    # --- DD-47: add kagent-nginx-dd47 volume if not present ---
    if 'kagent-nginx-dd47' not in raw:
        # Find the volumes: section and append our volume entry after sqlite-volume
        raw = re.sub(
            r'(      - emptyDir:.*?name: sqlite-volume)',
            r'\1\n      - configMap:\n          defaultMode: 420\n          name: kagent-nginx-dd47\n        name: kagent-nginx-dd47',
            raw,
            flags=re.DOTALL
        )

    # --- DD-47: add volumeMount on ui container if not present ---
    # The ui container section ends before the next container or end of containers list.
    # We look for the ui container block and add volumeMounts if missing.
    if 'mountPath: /etc/nginx/nginx.conf' not in raw:
        # Find the `- name: ui` container entry and append volumeMounts
        # Pattern: locate `        - name: ui` line and find its end (next `        - name:` or dedent)
        raw = re.sub(
            r'(        - name: ui\n(?:(?!        - name:).)*?)(        - name:|\Z)',
            lambda m: m.group(1) + (
                '          volumeMounts:\n'
                '          - mountPath: /etc/nginx/nginx.conf\n'
                '            name: kagent-nginx-dd47\n'
                '            readOnly: true\n'
                '            subPath: nginx.conf\n'
            ) + m.group(2),
            raw,
            flags=re.DOTALL
        )

    out_docs.append(raw)

print('---'.join(out_docs), end='')
PYEOF

python3 "$TMP_PY"
