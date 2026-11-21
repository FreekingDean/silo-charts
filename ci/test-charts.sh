#!/usr/bin/env bash
# Lints both charts, renders the combinations that have to keep rendering, and
# checks that the guards refuse what cannot work. A chart is only exercised by
# being rendered, and a guard nothing tests is a guard that stops firing.
#
# With kubeconform on PATH, every render is also checked against the
# Kubernetes schemas.
set -euo pipefail

cd "$(dirname "$0")/.."
KUBE_VERSION="${KUBE_VERSION:-1.31.0}"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
n=0

render() {
  local chart="$1"; shift
  n=$((n + 1))
  if ! helm template t "charts/$chart" --kube-version "$KUBE_VERSION" "$@" > "$out/$n.yaml"; then
    echo "failed to render $chart: $*" >&2
    exit 1
  fi
}

refuses() {
  local chart="$1"; shift
  if helm template t "charts/$chart" --kube-version "$KUBE_VERSION" "$@" > /dev/null 2>&1; then
    echo "rendered instead of failing: $chart $*" >&2
    exit 1
  fi
}

helm lint --strict --kube-version "$KUBE_VERSION" charts/silo-omnibus
helm lint --strict --kube-version "$KUBE_VERSION" charts/silo

# silo-omnibus
render silo-omnibus
render silo-omnibus --set netAdmin=false --set bundled.redis=false --set bundled.meilisearch=true \
  --set bundled.meilisearchMasterKey.existingSecret=meili
render silo-omnibus --set metrics.enabled=true --set persistence.downloadArtifacts.enabled=true \
  --set persistence.transcode.sizeLimit=50Gi --set persistence.config.existingClaim=silo-config
render silo-omnibus --set hostname=silo.example.test --set jellyfin.hostname=jf.example.test \
  --set audiobookshelf.hostname=abs.example.test --set httpRoute.enabled=true --set 'httpRoute.parentRefs[0].name=gateway'
render silo-omnibus --set settings.SILO_SIGNUP_ENABLED=false --set secretSettings.existingSecret=silo-settings \
  --set 'trustedProxies={10.42.0.0/16}' --set timeZone=Europe/London \
  --set-json 'media.extraVolumes=[{"name":"books","mountPath":"/mnt/books","volume":{"emptyDir":{}}}]' \
  --set-json 'persistence.catalogSeeds={"emptyDir":{}}' \
  --set-json 'env=[{"name":"HOST_IP","valueFrom":{"fieldRef":{"fieldPath":"status.hostIP"}}}]'
render silo-omnibus --set pod=null --set service.type=LoadBalancer --set service.externalTrafficPolicy=Local \
  --set-json 'resources={"limits":{"gpu.intel.com/i915":1}}'

refuses silo-omnibus --set httpRoute.enabled=true

# silo
render silo
render silo --set postgresql.enabled=false --set redis.enabled=false
render silo --set postgresql.enabled=false --set database.existingSecret=silo-db \
  --set redis.enabled=false --set redis.existingSecret=silo-redis --set proxy.enabled=true
render silo --set meilisearch.enabled=true --set metrics.enabled=true --set persistence.downloadArtifacts.enabled=true
render silo --set transcode.enabled=true --set transcode.replicas=3 --set transcode.hwAccel=vaapi \
  --set transcode.hwDevice=/dev/dri/renderD128 --set transcode.podDisruptionBudget.enabled=true
render silo --set transcode.enabled=true --set transcode.sourceAccess=core
render silo --set proxy.enabled=true --set 'proxy.publicUrl=https://$(POD_NAME).stream.example.test' \
  --set proxy.autoscaling.enabled=true --set proxy.podDisruptionBudget.enabled=true
render silo --set api.replicas=2 --set 'persistence.data.accessModes={ReadWriteMany}' \
  --set api.podDisruptionBudget.enabled=true
render silo --set api.autoscaling.enabled=true --set 'persistence.data.accessModes={ReadWriteMany}'
render silo --set hostname=silo.example.test --set jellyfin.hostname=jf.example.test \
  --set httpRoute.enabled=true --set 'httpRoute.parentRefs[0].name=gateway'
render silo --set pod=null --set api.resources=null --set postgresql.pod=null --set redis.pod=null
render silo --set postgresql.persistence.existingClaim=pg --set redis.persistence.existingClaim=redis \
  --set meilisearch.enabled=true --set meilisearch.persistence.existingClaim=meili \
  --set postgresql.existingSecret=pg-pass --set meilisearch.existingSecret=meili-key
render silo --set settings.SILO_SIGNUP_ENABLED=false --set secretSettings.existingSecret=silo-settings \
  --set-json 'env=[{"name":"HOST_IP","valueFrom":{"fieldRef":{"fieldPath":"status.hostIP"}}}]' \
  --set-json 'media.extraVolumes=[{"name":"books","mountPath":"/mnt/books","volume":{"emptyDir":{}}}]'

refuses silo --set httpRoute.enabled=true
refuses silo --set api.replicas=2
refuses silo --set api.replicas=2 --set 'persistence.data.accessModes={ReadWriteMany}' --set redis.enabled=false
refuses silo --set proxy.enabled=true --set redis.enabled=false
refuses silo --set transcode.enabled=true --set transcode.replicas=0
refuses silo --set transcode.enabled=true --set transcode.sourceAccess=nfs
refuses silo --set api.autoscaling.enabled=true --set 'persistence.data.accessModes={ReadWriteMany}' --set api.resources=null
refuses silo --set proxy.enabled=true --set proxy.autoscaling.enabled=true --set proxy.autoscaling.minReplicas=9

if command -v kubeconform > /dev/null; then
  kubeconform -strict -summary -kubernetes-version "$KUBE_VERSION" -ignore-missing-schemas "$out"/*.yaml
fi
echo "ok: $n renders"
