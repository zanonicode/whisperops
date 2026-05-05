# Single Source of Truth

> **Purpose**: When the same data needs to exist in multiple formats (JSON dashboards as YAML ConfigMaps, OpenAPI specs as TypeScript types, schemas as docs), pick one as the source and **generate** the others. Never hand-edit derived artifacts.
> **MCP Validated**: 2026-04-27

## When to Use

- Grafana dashboards (JSON, source) need to ship as Helm-templated ConfigMaps (YAML).
- OpenAPI/JSON Schema (source) needs to produce client SDK types.
- Pydantic models (source) need to produce JSON Schema for external consumers.
- Anywhere two artifacts contain the same fact and one is mechanically derivable from the other.

## When NOT to Use

- The two artifacts represent **different** facts that happen to look similar (don't conflate them).
- The derived format is consumed by humans for editing (then make the source the editable one).
- The transformation is so simple a human can do it reliably each time (rare; usually drift wins).

## The Pattern

```text
   +-----------+       generator        +-----------+        applier      +-----------+
   |  source   |  ------------------->  |  derived  |  ----------------->  |  cluster  |
   |  (JSON)   |  (`make regen-...`)    |  (YAML)   |  (`make apply-...`)  |           |
   +-----------+                        +-----------+                      +-----------+
        ^                                     |
        |                                     |
   hand-edited                          checked into git,
   only here                            never hand-edited
```

Three rules:
1. **The generator is the only writer of the derived artifact.** A pre-commit hook or CI check fails if the derived artifact is hand-edited.
2. **The derived artifact is checked in.** This makes diffs reviewable and avoids "regenerate at deploy time" surprises.
3. **The Make target that applies the derived artifact runs the generator first** (or fails if it would change anything).

## Implementation

### regen-configmaps.py (commit 8adea5e)

This repo had Grafana dashboards in `dashboards/*.json` and ConfigMaps in `charts/grafana-dashboards/templates/*.yaml`. Both were hand-edited. They drifted. Commit 8adea5e introduced the generator.

```python
# scripts/regen-configmaps.py
"""Regenerate Helm ConfigMap templates from dashboards/*.json.

Source of truth: dashboards/*.json (hand-edited).
Derived:        charts/grafana-dashboards/templates/<name>-cm.yaml (NEVER hand-edit).
"""
from __future__ import annotations

import json
from pathlib import Path
from textwrap import indent

REPO = Path(__file__).resolve().parents[1]
DASHBOARDS_DIR = REPO / "dashboards"
TEMPLATES_DIR = REPO / "charts" / "grafana-dashboards" / "templates"

CM_TEMPLATE = """\
{{- /* GENERATED FILE — do not hand-edit. Source: dashboards/{name}.json */ -}}
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ printf "%s-{name}" (include "grafana-dashboards.fullname" .) }}
  labels:
    {{- include "grafana-dashboards.labels" . | nindent 4 }}
    grafana_dashboard: "1"
data:
  {name}.json: |
{body}
"""

def render(name: str, payload: dict) -> str:
    pretty = json.dumps(payload, indent=2, sort_keys=True)
    body = indent(pretty, " " * 4)
    return CM_TEMPLATE.format(name=name, body=body)

def main() -> int:
    TEMPLATES_DIR.mkdir(parents=True, exist_ok=True)
    written = 0
    for src in sorted(DASHBOARDS_DIR.glob("*.json")):
        name = src.stem
        payload = json.loads(src.read_text())
        out = TEMPLATES_DIR / f"{name}-cm.yaml"
        rendered = render(name, payload)
        if not out.exists() or out.read_text() != rendered:
            out.write_text(rendered)
            written += 1
            print(f"wrote {out.relative_to(REPO)}")
    print(f"done; {written} file(s) updated")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
```

### Make integration

```makefile
.PHONY: regen-configmaps
regen-configmaps:           ## regenerate dashboard ConfigMaps from JSON
	python scripts/regen-configmaps.py

.PHONY: dashboards
dashboards: regen-configmaps  ## render + apply dashboards (cleans drift first)
	kubectl delete configmap -l grafana_dashboard=1 --ignore-not-found
	kubectl apply -f charts/grafana-dashboards/templates/

.PHONY: check-configmaps-fresh
check-configmaps-fresh:      ## CI: fail if generated files are stale
	python scripts/regen-configmaps.py
	git diff --exit-code charts/grafana-dashboards/templates/
```

CI runs `make check-configmaps-fresh`. If anyone hand-edited a `*-cm.yaml`, the regenerator overwrites their changes and `git diff --exit-code` fails the build.

### Optional: pre-commit hook

```yaml
# .pre-commit-config.yaml
- repo: local
  hooks:
    - id: regen-configmaps
      name: Regenerate dashboard ConfigMaps
      entry: python scripts/regen-configmaps.py
      language: system
      pass_filenames: false
      files: '^(dashboards/.*\.json|scripts/regen-configmaps\.py)$'
```

## Configuration

| Setting | Default | Description |
|---------|---------|-------------|
| Source dir | `dashboards/` | JSON source of truth |
| Output dir | `charts/grafana-dashboards/templates/` | Generated ConfigMaps |
| Header marker | `{{- /* GENERATED FILE ... */ -}}` | Required; CI greps for it on edits |
| CI check | `make check-configmaps-fresh` | Fails build if derived is stale |

## Example Usage

```bash
# Author edits a JSON dashboard
$EDITOR dashboards/sre-copilot-overview.json

# Regenerate the Helm artifacts
make regen-configmaps

# Apply to cluster
make dashboards

# Or in CI: ensure no hand-edits sneaked in
make check-configmaps-fresh
```

## Anti-Pattern

```yaml
# charts/grafana-dashboards/templates/sre-copilot-overview-cm.yaml
# (Hand-edited; no GENERATED header)
apiVersion: v1
kind: ConfigMap
metadata:
  name: sre-copilot-overview
data:
  sre-copilot-overview.json: |
    { "title": "SRE Copilot — Overview", "panels": [...] }   # diverged from dashboards/*.json a month ago
```

Two sources, both edited, drift inevitable. Symptoms: a panel looks right in Grafana UI ("Save dashboard" goes to the in-cluster JSON) but reverts on next `helmfile sync` (the chart YAML is the truth Helm applies). Or vice versa. The fight is unwinnable without a generator.

## See Also

- [append-not-replace.md](append-not-replace.md)
- [idempotent-make-targets.md](idempotent-make-targets.md)
- [conditional-helm-templates.md](conditional-helm-templates.md)
- [../concepts/spotting-complexity.md](../concepts/spotting-complexity.md)
- [../index.md](../index.md)
