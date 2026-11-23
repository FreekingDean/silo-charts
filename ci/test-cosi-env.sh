#!/usr/bin/env bash
# Runs the rendered cosi-env script against sample BucketInfo documents and
# checks exactly what it writes, in both modes. Needs mikefarah's yq, as the
# init container's image has.
set -euo pipefail

cd "$(dirname "$0")/.."
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

script() {
  helm template t charts/silo --kube-version 1.34.0 --set objectStorage.enabled=true \
    --set objectStorage.public.cosiSecret=a --set objectStorage.private.cosiSecret=b "$@" |
    yq 'select(.kind == "Deployment") | .spec.template.spec.initContainers[0].args[0]' |
    sed -e "s#/run/silo/s3#$work/run#g" -e "s#/cosi/#$work/cosi/#g"
}

info() {
  printf '{"spec":{"bucketName":"%s","secretS3":{"endpoint":"http://10.0.0.104:7480","accessKeyID":"AK","accessSecretKey":"%s"}}}' "$1" "$2"
}

setup() {
  rm -rf "$work/run" "$work/cosi"
  mkdir -p "$work/run" "$work/cosi/public" "$work/cosi/private"
  info "$1" "$2" > "$work/cosi/public/BucketInfo"
  info silo-private "s3cr3t" > "$work/cosi/private/BucketInfo"
}

expect() {
  if [ "$(cat "$1")" != "$2" ]; then
    printf 'unexpected %s:\n%s\n' "$1" "$(cat "$1")" >&2
    exit 1
  fi
}

fails() {
  if sh "$work/init.sh" 2> /dev/null; then
    echo "cosi-env accepted $1" >&2
    exit 1
  fi
}

# Sourced shell file: any value, quoted for sh.
script > "$work/init.sh"
setup silo-public "se'cr\$et\\\"x"
sh "$work/init.sh"
expect "$work/run/env" "export SILO_S3_PRIVATE_ENDPOINT='http://10.0.0.104:7480'
export SILO_S3_PRIVATE_BUCKET='silo-private'
export SILO_S3_PUBLIC_ENDPOINT='http://10.0.0.104:7480'
export SILO_S3_PUBLIC_BUCKET='silo-public'"
expect "$work/run/public/secret-key" "se'cr\$et\"x"
expect "$work/run/public/access-key" "AK"
[ "$(sh -c ". '$work/run/env' && printf %s \"\$SILO_S3_PUBLIC_BUCKET\"")" = silo-public ]

# EnvFiles: KEY='VALUE' lines only.
script --set objectStorage.cosi.envFiles=true > "$work/init.sh"
setup silo-public "se'cr\$et"
sh "$work/init.sh"
expect "$work/run/s3.env" "SILO_S3_PRIVATE_ENDPOINT='http://10.0.0.104:7480'
SILO_S3_PRIVATE_BUCKET='silo-private'
SILO_S3_PUBLIC_ENDPOINT='http://10.0.0.104:7480'
SILO_S3_PUBLIC_BUCKET='silo-public'"
expect "$work/run/public/secret-key" "se'cr\$et"
setup "silo'public" x
fails "a single quote in an env-file value"

# A missing field stops the pod.
script > "$work/init.sh"
setup silo-public x
echo '{"spec":{"bucketName":"b","secretS3":{}}}' > "$work/cosi/public/BucketInfo"
fails "a BucketInfo without an endpoint"

echo "ok: cosi-env"
