# Deploy Silo as components

This chart runs [Silo](https://github.com/Silo-Server/silo-server) split into the parts it already knows how to be: API servers, proxy nodes and transcode nodes, each its own workload, beside a PostgreSQL, Redis and Meilisearch of their own, or yours. It is upstream's `docker-compose.advanced.yml` plus its node modes, laid out for Kubernetes. Its values and structure follow the [gojellyfin chart](https://github.com/FreekingDean/gojellyfin/tree/main/charts/gojellyfin).

For one pod with everything bundled, use [`silo-omnibus`](../silo-omnibus).

## Install

`SECRET_KEY` is Silo's master key for at-rest credential encryption. The API and proxies refuse to start without it, and every one needs the same key. The chart never generates it. Create it and back it up apart from the database:

```sh
kubectl create secret generic silo \
  --from-literal SECRET_KEY="$(openssl rand -base64 48)"

helm install silo charts/silo \
  --set hostname=silo.example.com \
  --set-json 'media.volume={"persistentVolumeClaim":{"claimName":"media"}}'
```

With the release named `silo` the chart reads the Secret `silo`; set `secretKey.existingSecret` otherwise. The bundled PostgreSQL and Redis passwords are generated into `silo-postgresql` and `silo-redis` on first install and kept across upgrades and uninstalls. Open the web app to finish first-run setup.

### The smallest install

```yaml
hostname: silo.example.com
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
| `postgresql` | StatefulSet | | yes | `pgvector/pgvector:pg18` with `pg_stat_statements`, as the advanced compose file runs it |
| `redis` | StatefulSet | | yes | Append-only Redis with a password. Watch Party, proxies and multi-API need it |
| `meilisearch` | StatefulSet | | no | Pinned Meilisearch for search |

There is no migration Job: Silo migrates at API startup, under a lock, and backs the database up first. The API's startup probe allows 22.5 minutes for that.

### API

One replica by default. More need `persistence.data` to be `ReadWriteMany` (artwork, plugins and the Jellyfin web client live there and every API pod writes them) and Redis; the chart refuses to render either combination without them. With the data volume `ReadWriteOnce`, the Deployment uses `Recreate` so the new pod can attach it. Silo supports only one API replica while network access provider plugins (Tailscale and similar) are installed.

On SIGTERM the API fails `/api/v1/ready` at once and keeps serving for `drainSeconds` (`SILO_SHUTDOWN_DELAY`), so gateways move on before it closes. The grace period is `drainSeconds` plus 90 seconds, as upstream asks.

### Proxy nodes

Proxies stream to players directly. Each pod's identity is its own address, `http://<pod>.<fullname>-proxy.<namespace>.svc.<clusterDomain>:8080`, behind a headless Service, and it registers itself (`SILO_NODE_REGISTER=true`) with its pod name as its node name. Players are handed `SILO_NODE_PUBLIC_URL`, which has to reach that one pod. Set `proxy.publicUrl` with `$(POD_NAME)` in it, which Kubernetes expands per pod, and give each pod a route of its own:

```yaml
proxy:
  enabled: true
  replicas: 2
  publicUrl: https://$(POD_NAME).stream.example.com
```

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
| `database.existingSecret`, `.secretKey` | `DATABASE_URL` | `""`, `DATABASE_URL` | Used when `postgresql.enabled` is false. It needs pgvector and a role that may create `vector`, `pg_trgm` and `citext` |
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
| `persistence.data.*` | 20Gi RWO | `/config/silo` (`/var/lib/silo`) on the API. Kept on uninstall |
| `persistence.transcode.sizeLimit` | `""` | The API's `/tmp/silo-transcode` `emptyDir` |
| `persistence.downloadArtifacts.*` | off | The API's prepared downloads. Off is an `emptyDir` |

### Workloads

| Value | Default | Description |
|---|---|---|
| `api.replicas` | `1` | See [API](#api) |
| `api.startupProbe.*` | `15`, `90` | Covers the 20-minute migration budget |
| `api.resources`, `.autoscaling.*`, `.podDisruptionBudget.*`, `.pod` | | As in gojellyfin. Autoscaling needs `resources.requests.cpu` |
| `proxy.enabled`, `.replicas` | `false`, `2` | |
| `proxy.publicUrl` | `""` | `SILO_NODE_PUBLIC_URL`; `$(POD_NAME)` expands per pod |
| `proxy.group`, `.maxStreams`, `.maxBandwidthKbps` | `""`, `0`, `0` | `SILO_NODE_GROUP`, `SILO_NODE_MAX_STREAMS`, `SILO_NODE_MAX_BANDWIDTH_KBPS` |
| `proxy.resources`, `.autoscaling.*`, `.podDisruptionBudget.*`, `.pod` | | |
| `transcode.enabled`, `.replicas` | `false`, `1` | |
| `transcode.keys.existingSecret` | `""` | Empty means `<fullname>-transcode-keys` |
| `transcode.sourceAccess` | `local` | `local` or `core` |
| `transcode.hwAccel`, `.hwDevice`, `.maxTranscodes`, `.group` | | `SILO_NODE_HW_ACCEL`, `SILO_NODE_HW_DEVICE`, `SILO_NODE_MAX_TRANSCODES`, `SILO_NODE_GROUP` |
| `transcode.drainTimeoutSeconds` | `600` | `SILO_NODE_DRAIN_TIMEOUT` |
| `transcode.scratch.sizeLimit`, `.resources`, `.podDisruptionBudget.*`, `.pod` | | |

### Bundled services

| Value | Default | Description |
|---|---|---|
| `postgresql.enabled` | `true` | Off, set `database.existingSecret` |
| `postgresql.image.*` | `pgvector/pgvector:pg18` | PostgreSQL refuses a data directory from another major version |
| `postgresql.existingSecret` | `""` | A Secret with `POSTGRES_PASSWORD` instead of the generated one; letters and digits only |
| `postgresql.shmSize`, `.persistence.*`, `.resources`, `.pod` | `1Gi`, 20Gi | |
| `redis.enabled` | `true` | Off, `redis.existingSecret` names a Secret holding `REDIS_URL` (key `redis.secretKey`); with neither the API runs without Redis |
| `redis.image.*`, `.persistence.*`, `.resources`, `.pod` | `redis:8.2-alpine`, 2Gi | |
| `meilisearch.enabled` | `false` | On, the API gets `SILO_SEARCH_PROVIDER=meilisearch` and its URL and key |
| `meilisearch.image.*` | `getmeili/meilisearch:v1.54.0` | Pinned: Meilisearch will not open data from another version. Set `upgradeDb` for one start after a bump |
| `meilisearch.existingSecret`, `.persistence.*`, `.resources`, `.pod` | `""`, 10Gi | |

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
