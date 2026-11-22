#!/usr/bin/env bash
# Installs one chart into the current cluster (minikube in CI) and checks that
# Silo comes up: every pod Ready, and the API answering /api/v1/health and
# /api/v1/ready. Usage: ci/install-test.sh silo-omnibus|silo
#
# The silo chart deploys only Silo, so this applies a test-only PostgreSQL and
# Redis (ci/fixtures/dependencies.yaml) first, and generates a transcode node
# key with the same image.
set -euo pipefail

cd "$(dirname "$0")/.."
chart="${1:?usage: $0 silo-omnibus|silo}"
image="${SILO_IMAGE:-ghcr.io/silo-server/silo-server:latest}"
timeout="${TIMEOUT:-20m}"
ns="$chart"
release="$chart"

dump() {
  echo "::group::cluster state"
  kubectl --namespace "$ns" get pods,svc,pvc -o wide || true
  kubectl --namespace "$ns" describe pods || true
  for pod in $(kubectl --namespace "$ns" get pods -o name); do
    echo "--- $pod"
    kubectl --namespace "$ns" logs "$pod" --all-containers --tail 200 || true
  done
  echo "::endgroup::"
}
trap 'dump' ERR

kubectl create namespace "$ns"
secret_key="$(openssl rand -base64 48)"

image_args=(--set image.repository="${image%:*}" --set image.tag="${image##*:}")

case "$chart" in
  silo-omnibus)
    kubectl --namespace "$ns" create secret generic "$release" --from-literal SECRET_KEY="$secret_key"
    helm install "$release" charts/silo-omnibus --namespace "$ns" "${image_args[@]}" \
      --wait --timeout "$timeout"
    svc="$release"
    ;;
  silo)
    kubectl --namespace "$ns" apply -f ci/fixtures/dependencies.yaml
    for d in postgres redis; do kubectl --namespace "$ns" rollout status "deploy/$d" --timeout 5m; done
    kubectl --namespace "$ns" create secret generic "$release" \
      --from-literal SECRET_KEY="$secret_key" \
      --from-literal DATABASE_URL='postgres://silo:silo@postgres:5432/silo?sslmode=disable'
    key="$(kubectl --namespace "$ns" run node-key --image "$image" --restart Never --rm -i -q \
      --command -- silo node-key generate --id 1001 | tr -d '\r\n')"
    [[ "$key" == snk1_1001_* ]] || { echo "unexpected node key output" >&2; exit 1; }
    kubectl --namespace "$ns" create secret generic "$release-transcode-keys" --from-literal 0="$key"
    # Small requests so every workload fits on one CI node.
    helm install "$release" charts/silo --namespace "$ns" "${image_args[@]}" \
      --set redis.existingSecret=silo-redis \
      --set api.resources.requests.cpu=100m --set api.resources.requests.memory=256Mi \
      --set proxy.enabled=true --set proxy.replicas=1 \
      --set proxy.resources.requests.cpu=100m --set proxy.resources.requests.memory=128Mi \
      --set transcode.enabled=true --set transcode.replicas=1 \
      --set transcode.resources.requests.cpu=100m --set transcode.resources.requests.memory=128Mi \
      --wait --timeout "$timeout"
    # The proxy and transcode node only pass their probes once they reached
    # the API: the node with its key, after the API declared it.
    for s in proxy transcode; do kubectl --namespace "$ns" rollout status "statefulset/$release-$s" --timeout 5m; done
    svc="$release"
    ;;
  *)
    echo "unknown chart $chart" >&2
    exit 2
    ;;
esac

kubectl --namespace "$ns" port-forward "svc/$svc" 18080:80 > /dev/null 2>&1 &
pf=$!
trap 'kill $pf 2>/dev/null || true' EXIT
for _ in $(seq 30); do
  curl -fsS http://127.0.0.1:18080/api/v1/health > /dev/null 2>&1 && break
  sleep 2
done
curl -fsS http://127.0.0.1:18080/api/v1/health
echo
curl -fsS http://127.0.0.1:18080/api/v1/ready
echo
kubectl --namespace "$ns" get pods
echo "ok: $chart installed and healthy"
