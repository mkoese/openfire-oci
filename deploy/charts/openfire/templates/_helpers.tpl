{{/*
Common labels applied to all resources.
*/}}
{{- define "openfire.labels" -}}
app: openfire
app.kubernetes.io/name: openfire
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Values.image.tag | quote }}
app.kubernetes.io/component: xmpp-server
app.kubernetes.io/managed-by: helm
{{- end }}

{{/*
Selector labels used in matchLabels and pod templates.
Must be a stable subset of the common labels.
*/}}
{{- define "openfire.selectorLabels" -}}
app: openfire
app.kubernetes.io/name: openfire
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
