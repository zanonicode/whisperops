{{- define "sandbox.fullname" -}}
{{- printf "%s" .Release.Name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "sandbox.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{ include "sandbox.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "sandbox.selectorLabels" -}}
app.kubernetes.io/name: sandbox
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
