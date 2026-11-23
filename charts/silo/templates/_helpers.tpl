{{- define "silo.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "silo.fullname" -}}
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

{{- define "silo.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "silo.selectorLabels" -}}
app.kubernetes.io/name: {{ include "silo.name" .root }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
app.kubernetes.io/component: {{ .component }}
{{- end }}

{{- define "silo.labels" -}}
helm.sh/chart: {{ include "silo.chart" .root }}
{{ include "silo.selectorLabels" . }}
{{- with .root.Chart.AppVersion }}
app.kubernetes.io/version: {{ . | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .root.Release.Service }}
{{- end }}

{{- define "silo.podLabels" -}}
{{- $selector := fromYaml (include "silo.selectorLabels" (dict "root" .root "component" .component)) }}
{{- toYaml (merge $selector (default dict .pod.labels)) }}
{{- end }}

{{- define "silo.serviceLabels" -}}
{{- $labels := fromYaml (include "silo.labels" (dict "root" .root "component" .component)) }}
{{- toYaml (merge $labels (default dict .root.Values.service.labels)) }}
{{- end }}

{{- define "silo.tag" -}}
{{- default .Chart.AppVersion .Values.image.tag }}
{{- end }}

{{- define "silo.image" -}}
{{- printf "%s:%s" .Values.image.repository (include "silo.tag" .) }}
{{- end }}

{{- define "silo.pullPolicy" -}}
{{- if .policy -}}
{{- .policy -}}
{{- else if eq (toString .tag) "latest" -}}
Always
{{- else -}}
IfNotPresent
{{- end -}}
{{- end }}

{{- define "silo.imagePullPolicy" -}}
{{- include "silo.pullPolicy" (dict "policy" .Values.image.pullPolicy "tag" (include "silo.tag" .)) }}
{{- end }}

{{- /*
Everything in a merged `pod:` block that is not one of the chart's own keys
goes into the pod spec as written.
*/}}
{{- define "silo.podSpec" -}}
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

{{- /* The shared pod block merged under a workload's own. */}}
{{- define "silo.mergePod" -}}
{{- $base := default dict .base }}
{{- toYaml (mergeOverwrite $base (deepCopy (default dict .root.Values.pod)) (deepCopy (default dict .pod))) }}
{{- end }}

{{- define "silo.spread" -}}
topologySpreadConstraints:
  - maxSkew: 1
    topologyKey: kubernetes.io/hostname
    whenUnsatisfiable: ScheduleAnyway
    labelSelector:
      matchLabels:
        {{- include "silo.selectorLabels" . | nindent 8 }}
{{- end }}

{{- define "silo.svcHost" -}}
{{- printf "%s.%s.svc.%s" .name .root.Release.Namespace .root.Values.clusterDomain }}
{{- end }}

{{- define "silo.secretKeySecretName" -}}
{{- default (include "silo.fullname" .) .Values.secretKey.existingSecret }}
{{- end }}

{{- define "silo.databaseSecretName" -}}
{{- default (include "silo.fullname" .) .Values.database.existingSecret }}
{{- end }}

{{- define "silo.transcodeKeysSecretName" -}}
{{- default (printf "%s-transcode-keys" (include "silo.fullname" .)) .Values.transcode.keys.existingSecret }}
{{- end }}

{{- define "silo.hasRedis" -}}
{{- if .Values.redis.existingSecret }}true{{ end }}
{{- end }}

{{- define "silo.coreUrl" -}}
{{- printf "http://%s:%v" (include "silo.svcHost" (dict "root" . "name" (include "silo.fullname" .))) .Values.service.port }}
{{- end }}

{{- define "silo.transcodeNodeUrl" -}}
{{- $name := printf "%s-transcode" (include "silo.fullname" .root) }}
{{- printf "http://%s-%v.%s:%v" $name .index (include "silo.svcHost" (dict "root" .root "name" $name)) .root.Values.ports.http }}
{{- end }}

{{- /* Every Silo workload: extra env first, then the pod's identity. */}}
{{- define "silo.commonEnv" -}}
{{- with .Values.env }}
{{- toYaml . }}
{{ end -}}
- name: POD_NAME
  valueFrom:
    fieldRef:
      fieldPath: metadata.name
- name: PORT
  value: {{ .Values.ports.http | quote }}
- name: TZ
  value: {{ default "Etc/UTC" .Values.timeZone | quote }}
{{- if .Values.metrics.enabled }}
- name: SILO_METRICS_LISTEN
  value: {{ printf ":%v" .Values.metrics.port | quote }}
{{- end }}
{{- end }}

{{- define "silo.secretKeyEnv" -}}
- name: SECRET_KEY
  valueFrom:
    secretKeyRef:
      name: {{ include "silo.secretKeySecretName" . }}
      key: {{ .Values.secretKey.secretKey }}
{{- end }}

{{- define "silo.databaseEnv" -}}
- name: DATABASE_URL
  valueFrom:
    secretKeyRef:
      name: {{ include "silo.databaseSecretName" . }}
      key: {{ .Values.database.secretKey }}
{{- end }}

{{- define "silo.redisEnv" -}}
{{- with .Values.redis.existingSecret }}
- name: REDIS_URL
  valueFrom:
    secretKeyRef:
      name: {{ . }}
      key: {{ $.Values.redis.secretKey }}
{{- end }}
{{- end }}

{{- define "silo.mediaVolume" -}}
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

{{- define "silo.mediaVolumeMount" -}}
- name: media
  mountPath: {{ .Values.media.mountPath }}
  readOnly: true
{{- range .Values.media.extraVolumes }}
- name: {{ .name }}
  mountPath: {{ .mountPath }}
  readOnly: true
{{- end }}
{{- end }}

{{- define "silo.scratchVolume" -}}
{{- if .sizeLimit }}
emptyDir:
  sizeLimit: {{ .sizeLimit }}
{{- else }}
emptyDir: {}
{{- end }}
{{- end }}

{{- define "silo.dataClaimName" -}}
{{- default (printf "%s-data" (include "silo.fullname" .)) .Values.persistence.data.existingClaim }}
{{- end }}

{{- define "silo.downloadsClaimName" -}}
{{- default (printf "%s-download-artifacts" (include "silo.fullname" .)) .Values.persistence.downloadArtifacts.existingClaim }}
{{- end }}

{{- define "silo.dataShared" -}}
{{- if or (not .Values.persistence.data.enabled) (has "ReadWriteMany" .Values.persistence.data.accessModes) }}true{{ end }}
{{- end }}

{{- define "silo.transcodeNodesDocument" -}}
apiVersion: 1
nodes:
{{- range $i := until (int .Values.transcode.replicas) }}
  {{ printf "%s-transcode-%d" (include "silo.fullname" $) $i }}:
    url: {{ include "silo.transcodeNodeUrl" (dict "root" $ "index" $i) }}
    key:
      fromFile: {{ printf "/run/silo/transcode-keys/%d" $i }}
{{- end }}
{{- end }}

{{- /* Proxy pod names a per-pod Service and route are rendered for. */}}
{{- define "silo.proxyPods" -}}
{{- $count := int .Values.proxy.replicas }}
{{- if .Values.proxy.autoscaling.enabled }}{{ $count = int .Values.proxy.autoscaling.maxReplicas }}{{ end }}
{{- $pods := list }}
{{- range $i := until $count }}
{{- $pods = append $pods (printf "%s-proxy-%d" (include "silo.fullname" $) $i) }}
{{- end }}
{{- toJson $pods }}
{{- end }}

{{- /*
SILO_S3_<PREFIX>_* for one bucket. An ObjectBucketClaim's ConfigMap and Secret
share its name; its endpoint is assembled from BUCKET_HOST and BUCKET_PORT. A
COSI bucket's endpoint, bucket and keys come from the env file the cosi-env
init container writes, so only the settings values hold are set here.
*/}}
{{- define "silo.s3Env" -}}
{{- $b := .bucket }}
{{- $p := .prefix }}
{{- if and $b.cosiSecret $b.objectBucketClaim }}
{{- fail (printf "objectStorage.%s takes objectBucketClaim or cosiSecret, not both" (lower $p)) }}
{{- end }}
{{- if $b.cosiSecret }}
{{- else if $b.objectBucketClaim }}
- name: SILO_OBC_{{ $p }}_HOST
  valueFrom:
    configMapKeyRef:
      name: {{ $b.objectBucketClaim }}
      key: BUCKET_HOST
- name: SILO_OBC_{{ $p }}_PORT
  valueFrom:
    configMapKeyRef:
      name: {{ $b.objectBucketClaim }}
      key: BUCKET_PORT
- name: SILO_S3_{{ $p }}_ENDPOINT
  value: "http://$(SILO_OBC_{{ $p }}_HOST):$(SILO_OBC_{{ $p }}_PORT)"
- name: SILO_S3_{{ $p }}_BUCKET
  valueFrom:
    configMapKeyRef:
      name: {{ $b.objectBucketClaim }}
      key: BUCKET_NAME
{{- else }}
{{- if not (and $b.endpoint $b.bucket $b.existingSecret) }}
{{- fail (printf "objectStorage.%s needs objectBucketClaim, cosiSecret, or endpoint, bucket and existingSecret" (lower $p)) }}
{{- end }}
- name: SILO_S3_{{ $p }}_ENDPOINT
  value: {{ $b.endpoint | quote }}
- name: SILO_S3_{{ $p }}_BUCKET
  value: {{ $b.bucket | quote }}
{{- end }}
- name: SILO_S3_{{ $p }}_REGION
  value: {{ $b.region | quote }}
- name: SILO_S3_{{ $p }}_PATH_STYLE
  value: {{ $b.pathStyle | quote }}
{{- with $b.urlAuth }}
- name: SILO_S3_{{ $p }}_URL_AUTH
  value: {{ . | quote }}
{{- end }}
{{- if $b.cosiSecret }}
- name: SILO_S3_{{ $p }}_ACCESS_KEY_FILE
  value: /run/silo/s3/{{ lower $p }}/access-key
- name: SILO_S3_{{ $p }}_SECRET_KEY_FILE
  value: /run/silo/s3/{{ lower $p }}/secret-key
{{- else }}
- name: SILO_S3_{{ $p }}_ACCESS_KEY
  valueFrom:
    secretKeyRef:
      name: {{ default $b.objectBucketClaim $b.existingSecret }}
      key: {{ $b.accessKeyKey }}
- name: SILO_S3_{{ $p }}_SECRET_KEY
  valueFrom:
    secretKeyRef:
      name: {{ default $b.objectBucketClaim $b.existingSecret }}
      key: {{ $b.secretKeyKey }}
{{- end }}
{{- end }}

{{- /* The buckets objectStorage configures, as PREFIX: values, in order. */}}
{{- define "silo.s3Buckets" -}}
{{- $out := dict }}
{{- if .Values.objectStorage.enabled }}
{{- $_ := set $out "PUBLIC" .Values.objectStorage.public }}
{{- with .Values.objectStorage.private }}
{{- if or .objectBucketClaim .cosiSecret .endpoint }}
{{- $_ := set $out "PRIVATE" . }}
{{- end }}
{{- end }}
{{- end }}
{{- toJson $out }}
{{- end }}

{{- define "silo.objectStorageEnv" -}}
{{- if .Values.objectStorage.enabled }}
- name: SILO_ARTWORK_STORAGE
  value: s3
{{- range $p, $b := include "silo.s3Buckets" . | fromJson }}
{{- include "silo.s3Env" (dict "prefix" $p "bucket" $b) }}
{{- end }}
{{- end }}
{{- end }}

{{- /* The COSI buckets, as PREFIX: credentialsSecretName. */}}
{{- define "silo.cosiBuckets" -}}
{{- $out := dict }}
{{- range $p, $b := include "silo.s3Buckets" . | fromJson }}
{{- with $b.cosiSecret }}{{ $_ := set $out $p . }}{{ end }}
{{- end }}
{{- toJson $out }}
{{- end }}

{{- /*
Writes each COSI BucketInfo's keys to /run/silo/s3/<prefix>/access-key and
secret-key, which Silo reads through SILO_S3_<PREFIX>_ACCESS_KEY_FILE and
_SECRET_KEY_FILE. Silo has no _FILE variant for the endpoint or bucket, so
those two go into /run/silo/s3/env as shell exports, which the API container
sources before it runs silo. A missing field stops the pod here rather than
leaving Silo half configured.
*/}}
{{- define "silo.cosiInitContainer" -}}
{{- $root := .root }}
{{- $image := $root.Values.objectStorage.cosi.image }}
- name: cosi-env
  image: {{ printf "%s:%s" $image.repository $image.tag }}
  imagePullPolicy: {{ include "silo.pullPolicy" (dict "policy" $image.pullPolicy "tag" $image.tag) }}
  command: ["/bin/sh", "-c"]
  args:
    - |
      set -eu
      out=/run/silo/s3/env
      : > "$out"
      get() {
        v="$(yq -p json -o json -r "$2 // \"\"" "$1")"
        if [ -z "$v" ]; then
          echo "$1 has no $2" >&2
          exit 1
        fi
      }
      export_var() {
        get "$1" "$3"
        printf "export %s='%s'\n" "$2" "$(printf '%s' "$v" | sed "s/'/'\\\\''/g")" >> "$out"
      }
      write_file() {
        get "$1" "$3"
        printf '%s' "$v" > "$2"
      }
      {{- range $p, $_ := .buckets }}
      f=/cosi/{{ lower $p }}/BucketInfo
      d=/run/silo/s3/{{ lower $p }}
      mkdir -p "$d"
      export_var "$f" SILO_S3_{{ $p }}_ENDPOINT .spec.secretS3.endpoint
      export_var "$f" SILO_S3_{{ $p }}_BUCKET .spec.bucketName
      write_file "$f" "$d/access-key" .spec.secretS3.accessKeyID
      write_file "$f" "$d/secret-key" .spec.secretS3.accessSecretKey
      {{- end }}
  {{- with .securityContext }}
  securityContext:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  volumeMounts:
    - name: s3-env
      mountPath: /run/silo/s3
    {{- range $p, $_ := .buckets }}
    - name: cosi-{{ lower $p }}
      mountPath: /cosi/{{ lower $p }}
      readOnly: true
    {{- end }}
{{- end }}
