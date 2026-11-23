# Deploy Silo as components

This chart runs [Silo](https://github.com/Silo-Server/silo-server) split into the parts it already knows how to be: API servers, proxy nodes and transcode nodes, each its own workload. It deploys only Silo. PostgreSQL, Redis and Meilisearch are yours to run (an operator such as CloudNativePG, a managed service, another chart) and are wired in through Secrets you create. Its values and structure follow the [gojellyfin chart](https://github.com/FreekingDean/gojellyfin/tree/main/charts/gojellyfin).

For one pod with everything bundled, use [`silo-omnibus`](../silo-omnibus).

## Install

You need a PostgreSQL with pgvector (no newer than 18, the image's `pg_dump` version) and, for Watch Party, proxies or more than one API pod, a Redis.

`SECRET_KEY` is Silo's master key for at-rest credential encryption. The API and proxies refuse to start without it, and every one needs the same key. The chart never generates it. Put it and `DATABASE_URL` in one Secret, and back the key up apart from the database:

```sh
kubectl create secret generic silo \
  --from-literal SECRET_KEY="$(openssl rand -base64 48)" \
  --from-literal DATABASE_URL='postgres://silo:password@postgres:5432/silo?sslmode=require'
kubectl create secret generic silo-redis \
  --from-literal REDIS_URL='redis://:password@redis:6379'

helm install silo charts/silo \
  --set hostname=silo.example.com \
  --set redis.existingSecret=silo-redis \
  --set-json 'media.volume={"persistentVolumeClaim":{"claimName":"media"}}'
```

With the release named `silo` the chart reads the Secret `silo`; set `secretKey.existingSecret` and `database.existingSecret` otherwise. Open the web app to finish first-run setup.

### The smallest install

```yaml
hostname: silo.example.com
redis:
  existingSecret: silo-redis
media:
  volume:
    persistentVolumeClaim:
      claimName: media
httpRoute:
  enabled: true
  parentRefs:
    - name: my-gateway
      namespace: gateway-system
```

## What it deploys

One image, `ghcr.io/silo-server/silo-server`, started as `silo` (not the image's `/init`) as uid 911, for every Silo workload. That is upstream's "run Silo without root" layout: no bundled services, no PUID mapping, no `FILE__` loading. Silo's own `_FILE` variables still work.

| Workload | Kind | `MODE` | Enabled by default | What it is |
|---|---|---|---|---|
| `api` | Deployment | `api` | yes | The web app, native, Jellyfin and Audiobookshelf APIs, scanner, background work. Runs migrations before it listens |
| `proxy` | StatefulSet | `proxy` | no | Stream egress nodes. Each registers itself on the main server by its own address |
| `transcode` | StatefulSet | `transcode` | no | Encode nodes. No database or Redis; configured by the API with a node key |

Proxies and transcode nodes are StatefulSets because each pod needs a stable identity: a proxy is keyed on the main server by its own URL, and a transcode node by the key its ordinal selects. They hold no volumes of their own.

There is no migration Job: Silo migrates at API startup, under a lock, and backs the database up first. The API's startup probe allows 22.5 minutes for that.

### API

One replica by default. More need Redis, and `persistence.data` either `ReadWriteMany` (artwork, plugins and the Jellyfin web client live there and every API pod writes them) or turned off for a [stateless API](#stateless-api); the chart refuses to render either combination without them. With the data volume `ReadWriteOnce`, the Deployment uses `Recreate` so the new pod can attach it. Silo supports only one API replica while network access provider plugins (Tailscale and similar) are installed.

On SIGTERM the API fails `/api/v1/ready` at once and keeps serving for `drainSeconds` (`SILO_SHUTDOWN_DELAY`), so gateways move on before it closes. The grace period is `drainSeconds` plus 90 seconds, as upstream asks.

### Stateless API

The API keeps some state on disk at `/config/silo`: local artwork and other blobs, the plugin cache, and the Jellyfin web client. Two values move it off the pod:

- `objectStorage` puts the blobs in S3-compatible buckets (`SILO_ARTWORK_STORAGE=s3`). `public` holds artwork, trickplay, markers, chapter images and downloaded subtitles; `private` holds avatars, diagnostics, job artifacts and backups at the default destination. Each bucket can be the name of a Rook/Ceph `ObjectBucketClaim`, whose ConfigMap and Secret supply the endpoint, bucket and keys.
- `persistence.data.enabled: false` mounts an `emptyDir` instead of a PVC.

Together they make the API stateless, and more than one API pod no longer needs a `ReadWriteMany` volume. A restart then loses only two things: the plugin cache, which Silo rebuilds from the archives it keeps in PostgreSQL (`plugin_archives`), and the Jellyfin web client, which is built on the pod from source and has to be reinstalled from the admin settings (only needed for Jellyfin clients that use the web UI). Without `objectStorage`, an `emptyDir` also loses artwork, subtitles, avatars and default-destination backups on every restart.

```yaml
persistence:
  data:
    enabled: false
objectStorage:
  enabled: true
  public:
    objectBucketClaim: silo-public
  private:
    objectBucketClaim: silo-private
```

For storage the chart cannot describe, such as a COSI `BucketAccess` whose bucket name is generated, leave `objectStorage` off and wire it yourself: an init container in `api.pod.initContainers`, its volumes in `api.extraVolumes`, and `SILO_ARTWORK_STORAGE` and the `SILO_S3_*` variables in `api.env`.

Point `objectStorage` at its buckets from the first install: once Silo has written to storage, moving it is a managed transition in Silo, not a values change.

### Proxy nodes

A proxy is a playback-only Silo. The API decides what a player gets and then hands it a stream URL on a proxy, so the bytes (direct play, remux, downloads) flow from proxy pods instead of the API pods. They let streaming bandwidth scale, or sit closer to the players, without adding API replicas. They are off by default: a single API pod streams itself, as the omnibus image does.

Proxies stream to players directly, and a player keeps talking to the proxy it was handed, so each pod is published on its own. Each pod's identity is its own address, `http://<pod>.<fullname>-proxy.<namespace>.svc.<clusterDomain>:8080`, behind a headless Service, and it registers itself (`SILO_NODE_REGISTER=true`) with its pod name as its node name.

Set `proxy.domain` and each pod `<pod>` is published as `<pod>.<domain>`: the chart gives it a Service of its own (selecting `statefulset.kubernetes.io/pod-name`), an HTTPRoute when `httpRoute.enabled`, and `SILO_NODE_PUBLIC_URL=<scheme>://<pod>.<domain>`. A wildcard DNS record and a wildcard certificate for `*.<domain>` on the Gateway cover every pod. With autoscaling on, Services and routes are rendered up to `proxy.autoscaling.maxReplicas`, so a pod that scales in leaves an idle route behind rather than a new pod with none.

```yaml
redis:
  existingSecret: silo-redis
proxy:
  enabled: true
  replicas: 2
  domain: stream.example.com   # silo-proxy-0.stream.example.com, silo-proxy-1...
httpRoute:
  enabled: true
  parentRefs:
    - name: my-gateway
```

To publish proxies some other way (a LoadBalancer per pod, an external proxy), leave `domain` empty and set `proxy.publicUrl`, in which `$(POD_NAME)` expands per pod.

Proxies need the database, Redis and `SECRET_KEY`. They do not drain: a proxy holds no session it could finish on its own.

### Transcode nodes

Each transcode pod reads its key from a Secret whose keys are the pod ordinals (`0`, `1`, ...), selected through the `apps.kubernetes.io/pod-index` label (Kubernetes 1.28 and later). The API declares every node through `SILO_TRANSCODE_NODES_FILE`, a ConfigMap the chart writes, with each node's per-pod address behind a headless Service that publishes not-ready addresses, so a draining node stays reachable. Nothing has to be added in the admin UI.

A key names its node's id, so generate one per pod with ids no node has used:

```sh
img=ghcr.io/silo-server/silo-server:latest
kubectl create secret generic silo-transcode-keys \
  --from-literal 0="$(docker run --rm --entrypoint silo $img node-key generate --id 1001)" \
  --from-literal 1="$(docker run --rm --entrypoint silo $img node-key generate --id 1002)"
```

```yaml
transcode:
  enabled: true
  replicas: 2
  hwAccel: vaapi
  hwDevice: /dev/dri/renderD128
  resources:
    limits:
      gpu.intel.com/i915: 1
```

`transcode.replicas` is fixed by the keys, so it has no autoscaler. On SIGTERM a node drains for up to `transcode.drainTimeoutSeconds` (`SILO_NODE_DRAIN_TIMEOUT`), and the pod's grace period is that plus a minute. With `sourceAccess: core` a node streams media from the API and mounts none.

Turning `transcode.enabled` off stops declaring nodes but leaves the ones already declared on the main server. Release them with `settings.SILO_TRANSCODE_NODES: '{"apiVersion":1,"nodes":{}}'` for one start.

## Values

### Image, naming, ports

| Value | Default | Description |
|---|---|---|
| `image.repository` | `ghcr.io/silo-server/silo-server` | The one image every Silo workload runs |
| `image.tag` | `""` | Empty takes the chart's `appVersion`. Every workload shares it: the API migrates the schema the proxies read |
| `image.pullPolicy` | `""` | Empty is `Always` for `latest` and `IfNotPresent` otherwise |
| `nameOverride`, `fullnameOverride` | `""` | Resource naming |
| `clusterDomain` | `cluster.local` | DNS suffix in each node's address |
| `ports.http`, `.jellyfin`, `.audiobookshelf` | `8080`, `8096`, `13378` | `PORT`, `JF_PORT`, `ABS_PORT` |

### Server environment

| Value | Environment variable | Default | Description |
|---|---|---|---|
| `hostname` | `SILO_PUBLIC_URL` | `""` | The name clients reach the server by, as `<scheme>://<hostname>` |
| `scheme` | | `https` | What the gateway listens on |
| `jellyfin.hostname` | `SILO_JELLYFIN_PUBLIC_URL` | `""` | Route and public URL for the Jellyfin/Emby listener |
| `audiobookshelf.hostname` | | `""` | Route for the Audiobookshelf listener |
| `secretKey.existingSecret`, `.secretKey` | `SECRET_KEY` | `""`, `SECRET_KEY` | Empty means the release's fullname |
| `database.existingSecret`, `.secretKey` | `DATABASE_URL` | `""`, `DATABASE_URL` | Required. Empty means the release's fullname. pgvector, PostgreSQL 18 at most, and a role that may create `vector`, `pg_trgm` and `citext` |
| `redis.existingSecret`, `.secretKey` | `REDIS_URL` | `""`, `REDIS_URL` | Optional for one API pod; required for proxies and several API pods |
| `timeZone` | `TZ` | `""` | Empty is `Etc/UTC` |
| `trustedProxies` | `SILO_TRUSTED_PROXIES` | `[]` | The gateway's networks |
| `settings` | anything | `{}` | API server settings as `NAME: value`, the variables `.env.example` lists. `POSTGRES_TUNE` is off unless you set it here |
| `secretSettings.existingSecret` | anything | `""` | A Secret of variable names, loaded into the API with `envFrom` |
| `env` | anything | `[]` | Extra env for every Silo workload, rendered first |
| `drainSeconds` | `SILO_SHUTDOWN_DELAY` | `5` | How long a stopping API pod keeps serving |
| `metrics.enabled`, `.port` | `SILO_METRICS_LISTEN` | `false`, `9090` | The Prometheus listener on every Silo workload |

### Storage

| Value | Default | Description |
|---|---|---|
| `media.mountPath`, `.volume`, `.extraVolumes` | `/mnt/media`, `{}`, `[]` | Media, read-only, at the same path in every pod that reads it. Empty `volume` is an `emptyDir` |
| `persistence.data.enabled` | `true` | Off mounts an `emptyDir`; see [Stateless API](#stateless-api) |
| `persistence.data.*` | 20Gi RWO | `/config/silo` (`/var/lib/silo`) on the API. Kept on uninstall |
| `objectStorage.enabled`, `.public.*`, `.private.*` | off | S3-compatible buckets for Silo's blobs: `objectBucketClaim`, or `endpoint`, `bucket`, `region`, `pathStyle`, `existingSecret` with `accessKeyKey`/`secretKeyKey`; `public.urlAuth` |
| `persistence.transcode.sizeLimit` | `""` | The API's `/tmp/silo-transcode` `emptyDir` |
| `persistence.downloadArtifacts.*` | off | The API's prepared downloads. Off is an `emptyDir` |

### Workloads

| Value | Default | Description |
|---|---|---|
| `api.replicas` | `1` | See [API](#api) |
| `api.startupProbe.*` | `15`, `90` | Covers the 20-minute migration budget |
| `api.resources`, `.autoscaling.*`, `.podDisruptionBudget.*`, `.pod` | | As in gojellyfin. Autoscaling needs `resources.requests.cpu` |
| `api.env`, `api.envFrom` | `[]` | Env and `envFrom` for the API container only, after the chart's own, so a name here replaces the chart's. Any `valueFrom` works, `fileKeyRef` included |
| `api.extraVolumes`, `api.extraVolumeMounts` | `[]` | Volumes for API pods and where the API container mounts them; `api.pod.initContainers` can mount them too |
| `proxy.enabled`, `.replicas` | `false`, `2` | |
| `proxy.domain` | `""` | Publish each pod as `<pod>.<domain>`: a Service, an HTTPRoute and `SILO_NODE_PUBLIC_URL` per pod |
| `proxy.publicUrl` | `""` | `SILO_NODE_PUBLIC_URL` as written, instead of `domain`; `$(POD_NAME)` expands per pod |
| `proxy.group`, `.maxStreams`, `.maxBandwidthKbps` | `""`, `0`, `0` | `SILO_NODE_GROUP`, `SILO_NODE_MAX_STREAMS`, `SILO_NODE_MAX_BANDWIDTH_KBPS` |
| `proxy.resources`, `.autoscaling.*`, `.podDisruptionBudget.*`, `.pod` | | |
| `transcode.enabled`, `.replicas` | `false`, `1` | |
| `transcode.keys.existingSecret` | `""` | Empty means `<fullname>-transcode-keys` |
| `transcode.sourceAccess` | `local` | `local` or `core` |
| `transcode.hwAccel`, `.hwDevice`, `.maxTranscodes`, `.group` | | `SILO_NODE_HW_ACCEL`, `SILO_NODE_HW_DEVICE`, `SILO_NODE_MAX_TRANSCODES`, `SILO_NODE_GROUP` |
| `transcode.drainTimeoutSeconds` | `600` | `SILO_NODE_DRAIN_TIMEOUT` |
| `transcode.scratch.sizeLimit`, `.resources`, `.podDisruptionBudget.*`, `.pod` | | |

### Search

Without Meilisearch, Silo searches PostgreSQL. To use one you run, set `SILO_SEARCH_PROVIDER: meilisearch` and `SILO_MEILISEARCH_URL` in `settings` and `SILO_MEILISEARCH_API_KEY` in the `secretSettings` Secret.

### Pods, Services, routes

| Value | Default | Description |
|---|---|---|
| `pod.*` | uid 911, all capabilities dropped | Merged into every pod; a workload's own `pod` overrides it key by key. `annotations`, `labels` and `containerSecurityContext` are the chart's, anything else goes into the pod spec as written. Add the media's group to `pod.securityContext.supplementalGroups` if uid 911 cannot read it |
| `service.type`, `.port`, `.annotations`, `.labels` | `ClusterIP`, `80` | The API Service: `http` on `port`, `jellyfin` 8096, `abs` 13378 |
| `httpRoute.enabled`, `.parentRefs`, `.annotations` | off | One route per hostname. Enabling without a `parentRef` refuses to render |

## Things this chart does not do

- **`NET_ADMIN`.** It never reaches a non-root process, so Silo runs without BBR and send-buffer tuning and logs the limits it cannot change. `net.ipv4.tcp_wmem` is a safe pod sysctl from Kubernetes 1.32 and can go in `pod.securityContext.sysctls`.
- **Separate web frontend.** The API serves the web app from its binary.
- **Shared PostgreSQL connections.** With proxies and several API pods, size PostgreSQL's `max_connections` for 20 per Silo process plus admin sessions (`POSTGRES_TUNE_CONNECTIONS` in `settings` when tuning is on).
