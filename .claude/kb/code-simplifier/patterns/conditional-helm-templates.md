# Conditional Helm Templates

> **Purpose**: One chart that produces either a `Deployment` or an Argo Rollout (`Rollout`) based on a value flag, with the HPA's `scaleTargetRef.kind` switching to match. Avoids forking the chart on a boolean.
> **MCP Validated**: 2026-04-27

## When to Use

- A workload can be deployed as either a Deployment or a Rollout (canary opt-in).
- A chart needs to support two near-identical CRDs differing in `kind` and a few fields.
- You're tempted to copy the entire chart with one field renamed — stop, conditionalize.

## When NOT to Use

- The two outputs differ in **shape**, not just a few fields (e.g., a StatefulSet vs Deployment — different volume semantics, different ordering guarantees). Two charts is correct.
- The two outputs target different release lifecycles (one stable, one experimental). Keep separate so the experimental doesn't drag the stable.
- More than ~30% of the template diverges across the conditional. The conditional becomes harder to read than two files.

## Implementation

### `charts/backend/templates/workload.yaml`

```yaml
{{- if .Values.useArgoRollouts }}
apiVersion: argoproj.io/v1alpha1
kind: Rollout
{{- else }}
apiVersion: apps/v1
kind: Deployment
{{- end }}
metadata:
  name: {{ include "backend.fullname" . }}
  labels:
    {{- include "backend.labels" . | nindent 4 }}
spec:
  replicas: {{ .Values.replicas }}
  selector:
    matchLabels:
      {{- include "backend.selectorLabels" . | nindent 6 }}
  {{- if .Values.useArgoRollouts }}
  strategy:
    canary:
      canaryService: {{ include "backend.fullname" . }}-canary
      stableService: {{ include "backend.fullname" . }}
      trafficRouting:
        traefik:
          weightedTraefikServiceName: {{ include "backend.fullname" . }}
      steps:
        {{- toYaml .Values.rollout.steps | nindent 8 }}
  {{- else }}
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 25%
      maxUnavailable: 25%
  {{- end }}
  template:
    metadata:
      labels:
        {{- include "backend.selectorLabels" . | nindent 8 }}
    spec:
      containers:
        - name: backend
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
          ports:
            - containerPort: {{ .Values.service.port }}
          {{- with .Values.resources }}
          resources:
            {{- toYaml . | nindent 12 }}
          {{- end }}
```

The pod template (the bulk of the file) is shared. Only the apiVersion/kind line and the strategy block are conditional.

### `charts/backend/templates/hpa.yaml` — track the workload kind

```yaml
{{- if .Values.autoscaling.enabled }}
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: {{ include "backend.fullname" . }}
spec:
  scaleTargetRef:
    apiVersion: {{ if .Values.useArgoRollouts }}argoproj.io/v1alpha1{{ else }}apps/v1{{ end }}
    kind:       {{ if .Values.useArgoRollouts }}Rollout{{ else }}Deployment{{ end }}
    name:       {{ include "backend.fullname" . }}
  minReplicas: {{ .Values.autoscaling.minReplicas }}
  maxReplicas: {{ .Values.autoscaling.maxReplicas }}
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: {{ .Values.autoscaling.targetCPUUtilization }}
{{- end }}
```

If `useArgoRollouts` is true and the HPA still says `kind: Deployment`, the HPA scales nothing (the named Deployment doesn't exist). Track the workload kind. This is exactly the kind of landmine [../concepts/landmines.md](../concepts/landmines.md) catalogs — surface validation passes (the HPA is healthy from the API server's view), semantic intent is silently dropped.

### `values.yaml`

```yaml
useArgoRollouts: false       # default to Deployment for safety

replicas: 3

image:
  repository: ghcr.io/example/backend
  tag: latest

service:
  port: 8080

resources:
  requests:
    cpu: 100m
    memory: 256Mi

autoscaling:
  enabled: false
  minReplicas: 2
  maxReplicas: 10
  targetCPUUtilization: 70

rollout:
  steps:
    - setWeight: 25
    - pause: { duration: 2m }
    - setWeight: 50
    - pause: { duration: 5m }
    - setWeight: 100
```

## Configuration

| Setting | Default | Description |
|---------|---------|-------------|
| `useArgoRollouts` | `false` | Switch produced workload between Deployment and Rollout |
| `rollout.steps` | (sane default) | Canary step list, used only when `useArgoRollouts: true` |
| `autoscaling.enabled` | `false` | Whether to render an HPA at all |

## Example Usage

```bash
# Plain Deployment install
helm install backend ./charts/backend

# Argo Rollouts canary install
helm install backend ./charts/backend --set useArgoRollouts=true

# helmfile alternative
helmfile sync --set 'releases[0].values[0].useArgoRollouts=true'

# Confirm the right HPA kind was rendered
helm template backend ./charts/backend --set useArgoRollouts=true \
  | yq 'select(.kind == "HorizontalPodAutoscaler") | .spec.scaleTargetRef'
# expected: { apiVersion: argoproj.io/v1alpha1, kind: Rollout, name: backend }
```

## Anti-Pattern

### Forking the chart

```text
charts/
  backend/             # uses Deployment
  backend-rollout/     # 95% identical, uses Rollout
```

Now every change happens twice. They drift. Worse, the canary chart's defaults trail the stable chart's defaults; new resource limits, new env vars, new probes get added to one and forgotten in the other.

### HPA hard-coded to Deployment

```yaml
# Always points at Deployment, even when the chart renders a Rollout
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: {{ include "backend.fullname" . }}
```

The HPA "exists" but scales nothing in the canary configuration. CPU climbs, no replicas added, latency degrades, no alert fires (the HPA is healthy from its own view).

### Overusing conditionals

```yaml
# 12 nested {{- if }} blocks for marginal cases — pull the divergent half into a partial
{{- if .Values.useArgoRollouts }}
{{- if .Values.rollout.useExperimentalAnalysis }}
{{- if eq .Values.rollout.trafficRouting.kind "traefik" }}
...
```

When the conditionality dominates the readability, extract a partial template (`_rollout_strategy.tpl`) and `include` it. The rule of thumb: if the conditional has more than 3 levels of nesting, extract.

## See Also

- [single-source-of-truth.md](single-source-of-truth.md)
- [fail-loud-not-silent.md](fail-loud-not-silent.md)
- [../concepts/landmines.md](../concepts/landmines.md)
- [../concepts/the-collapse-test.md](../concepts/the-collapse-test.md)
- [../../helm-helmfile/index.md](../../helm-helmfile/index.md)
- [../../argo-rollouts/index.md](../../argo-rollouts/index.md)
- [../index.md](../index.md)
