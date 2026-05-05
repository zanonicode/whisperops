{{- define "chat-frontend.fullname" -}}
{{- printf "%s" .Release.Name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "chat-frontend.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{ include "chat-frontend.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "chat-frontend.selectorLabels" -}}
app.kubernetes.io/name: chat-frontend
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
