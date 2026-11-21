{{- define "silo-omnibus.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "silo-omnibus.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{- define "silo-omnibus.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "silo-omnibus.selectorLabels" -}}
app.kubernetes.io/name: {{ include "silo-omnibus.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: server
{{- end }}

{{- define "silo-omnibus.labels" -}}
helm.sh/chart: {{ include "silo-omnibus.chart" . }}
{{ include "silo-omnibus.selectorLabels" . }}
{{- with .Chart.AppVersion }}
app.kubernetes.io/version: {{ . | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "silo-omnibus.podLabels" -}}
{{- $selector := fromYaml (include "silo-omnibus.selectorLabels" .root) }}
{{- toYaml (merge $selector (default dict .pod.labels)) }}
{{- end }}

{{- define "silo-omnibus.serviceLabels" -}}
{{- $labels := fromYaml (include "silo-omnibus.labels" .) }}
{{- toYaml (merge $labels (default dict .Values.service.labels)) }}
{{- end }}

{{- define "silo-omnibus.tag" -}}
{{- default .Chart.AppVersion .Values.image.tag }}
{{- end }}

{{- define "silo-omnibus.image" -}}
{{- printf "%s:%s" .Values.image.repository (include "silo-omnibus.tag" .) }}
{{- end }}

{{- define "silo-omnibus.imagePullPolicy" -}}
{{- if .Values.image.pullPolicy -}}
{{- .Values.image.pullPolicy -}}
{{- else if eq (include "silo-omnibus.tag" .) "latest" -}}
Always
{{- else -}}
IfNotPresent
{{- end -}}
{{- end }}

{{- /*
Everything in a `pod:` block that is not one of the chart's own keys goes into
the pod spec as written.
*/}}
{{- define "silo-omnibus.podSpec" -}}
{{- range $field, $value := omit . "annotations" "labels" "containerSecurityContext" }}
{{- if or (kindIs "bool" $value) (kindIs "float64" $value) (kindIs "int64" $value) (kindIs "int" $value) $value }}
{{ $field }}:
{{- if or (kindIs "map" $value) (kindIs "slice" $value) }}
{{- toYaml $value | nindent 2 }}
{{- else }} {{ $value }}
{{- end }}
{{- end }}
{{- end }}
{{- end }}

{{- define "silo-omnibus.secretKeySecretName" -}}
{{- default (include "silo-omnibus.fullname" .) .Values.secretKey.existingSecret }}
{{- end }}

{{- define "silo-omnibus.publicUrl" -}}
{{- with .Values.hostname }}{{ printf "%s://%s" $.Values.scheme . }}{{ end }}
{{- end }}

{{- define "silo-omnibus.mediaVolume" -}}
- name: media
{{- if .Values.media.volume }}
  {{- toYaml .Values.media.volume | nindent 2 }}
{{- else }}
  emptyDir: {}
{{- end }}
{{- range .Values.media.extraVolumes }}
- name: {{ .name }}
  {{- toYaml .volume | nindent 2 }}
{{- end }}
{{- end }}

{{- define "silo-omnibus.mediaVolumeMount" -}}
- name: media
  mountPath: {{ .Values.media.mountPath }}
  readOnly: true
{{- range .Values.media.extraVolumes }}
- name: {{ .name }}
  mountPath: {{ .mountPath }}
  readOnly: true
{{- end }}
{{- end }}

{{- define "silo-omnibus.configClaimName" -}}
{{- default (printf "%s-config" (include "silo-omnibus.fullname" .)) .Values.persistence.config.existingClaim }}
{{- end }}

{{- define "silo-omnibus.downloadsClaimName" -}}
{{- default (printf "%s-download-artifacts" (include "silo-omnibus.fullname" .)) .Values.persistence.downloadArtifacts.existingClaim }}
{{- end }}
