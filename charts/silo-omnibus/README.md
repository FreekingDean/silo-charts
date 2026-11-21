# Deploy Silo in one pod

This chart runs Silo's all-in-one image, `ghcr.io/silo-server/silo-server`, as one Deployment: Silo, its PostgreSQL, and optionally Redis and Meilisearch in one container, supervised by s6. It is upstream's `docker-compose.yml` on Kubernetes. Everything Silo keeps lives on one volume, `/config`.

For Silo split into separately scaled pieces, use the [`silo`](../silo) chart.

## Install

Silo will not start without `SECRET_KEY`, its master key for at-rest credential encryption. The chart never generates it. Create it, and back it up apart from the database:

```sh
kubectl create secret generic silo \
  --from-literal SECRET_KEY="$(openssl rand -base64 48)"

helm install silo charts/silo-omnibus \
  --set hostname=silo.example.com \
  --set-json 'media.volume={"persistentVolumeClaim":{"claimName":"media"}}'
```

If the release is named `silo`, the chart looks for a Secret with that name. Set `secretKey.existingSecret` otherwise.

Open the web app (`kubectl port-forward svc/silo 8080:80`, or through the route) to finish first-run setup.

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

| Resource | What it is |
|---|---|
| Deployment | One pod, `Recreate` on update. PostgreSQL lives inside it, and a second pod on the same `/config` is refused the database lock |
| PersistentVolumeClaim `<fullname>-config` | `/config`: Silo's state, the PostgreSQL cluster, Redis and Meilisearch data. Kept on uninstall |
| Service | `http` on `service.port` (80), `jellyfin` on 8096, `abs` on 13378 |
| HTTPRoute (optional) | `hostname` to the web app and API; `jellyfin.hostname` and `audiobookshelf.hostname` to their listeners |

The image's `/init` runs as root, maps the `silo` account onto `puid`/`pgid`, re-owns `/config/silo`, and drops to that account for Silo. So this chart does not set `runAsUser` or drop capabilities; it adds `NET_ADMIN` (`netAdmin`) as the compose file does. Pod Security baseline and restricted refuse that; set `netAdmin: false` there. If you need a non-root pod, use the `silo` chart.

## Values

### Image and naming

| Value | Default | Description |
|---|---|---|
| `image.repository` | `ghcr.io/silo-server/silo-server` | The omnibus image |
| `image.tag` | `""` | Empty takes the chart's `appVersion` (`latest` in a checkout). Pin a `build-N` tag: the image carries PostgreSQL's major version, and refuses a data directory written by another |
| `image.pullPolicy` | `""` | Empty is `Always` for `latest` and `IfNotPresent` otherwise |
| `nameOverride`, `fullnameOverride` | `""` | Resource naming |

### Server

| Value | Environment variable | Default | Description |
|---|---|---|---|
| `hostname` | `SILO_PUBLIC_URL` | `""` | The name clients reach the server by; advertised as `<scheme>://<hostname>` and matched by the route |
| `scheme` | | `https` | What the gateway listens on |
| `jellyfin.hostname` | `SILO_JELLYFIN_PUBLIC_URL` | `""` | Route and public URL for the Jellyfin/Emby-compatible listener |
| `audiobookshelf.hostname` | | `""` | Route for the Audiobookshelf listener |
| `secretKey.existingSecret` | `SECRET_KEY` | `""` | Secret holding the master key. Empty means the release's fullname |
| `secretKey.secretKey` | | `SECRET_KEY` | Key within it |
| `puid`, `pgid` | `PUID`, `PGID` | `1000` | The account Silo runs as. It needs read access to the media |
| `timeZone` | `TZ` | `""` | Empty is `Etc/UTC` |
| `trustedProxies` | `SILO_TRUSTED_PROXIES` | `[]` | The gateway's networks, usually the pod CIDR |
| `bundled.redis` | `ENABLE_REDIS` | `true` | Start the bundled Redis. Watch Party needs it |
| `bundled.meilisearch` | `ENABLE_MEILISEARCH` | `false` | Start the bundled Meilisearch |
| `bundled.meilisearchMasterKey.existingSecret` | `MEILI_MASTER_KEY` | `""` | Empty lets the image generate one under `/config` |
| `settings` | anything | `{}` | Server settings as `NAME: value`, the variables `.env.example` lists (`SILO_SMTP_HOST`, `POSTGRES_TUNE`, `SILO_HW_ACCEL`, ...). A set variable shows its setting read-only in the admin UI |
| `secretSettings.existingSecret` | anything | `""` | A Secret whose keys are variable names, loaded with `envFrom`: `SILO_SMTP_PASSWORD`, `SILO_TMDB_API_KEY`, ... |
| `env` | anything | `[]` | Extra container env in Kubernetes' shape, rendered first so other values can refer to it as `$(NAME)` |
| `metrics.enabled`, `metrics.port` | `SILO_METRICS_LISTEN` | `false`, `9090` | The opt-in Prometheus listener, also added to the Service |
| `ports.http`, `ports.jellyfin`, `ports.audiobookshelf` | `PORT`, `JF_PORT`, `ABS_PORT` | `8080`, `8096`, `13378` | Container listeners |
| `netAdmin` | | `true` | Add `NET_ADMIN`, for BBR and larger send buffers on client connections |
| `terminationGracePeriodSeconds` | | `120` | Room for Silo's shutdown delay, in-flight requests and PostgreSQL's stop |
| `startupProbe.periodSeconds`, `startupProbe.failureThreshold` | | `15`, `90` | 22.5 minutes, which covers the default 20-minute migration budget (`SILO_MIGRATE_TIMEOUT`). Raise it with that |

### Storage

| Value | Default | Description |
|---|---|---|
| `media.mountPath` | `/mnt/media` | Where the media appears, read-only. Keep it at the path an existing library was scanned under |
| `media.volume` | `{}` | Any volume source. Empty is an `emptyDir`, a library with nothing in it |
| `media.extraVolumes` | `[]` | More media, each `name`, `mountPath` and `volume` |
| `persistence.config.*` | 20Gi RWO | `/config`. `existingClaim` to use your own; `storageClass` `-` for none |
| `persistence.transcode.existingClaim`, `.sizeLimit` | `""` | `/tmp/silo-transcode`, an `emptyDir` unless a claim is named |
| `persistence.downloadArtifacts.*` | off | `/tmp/silo-download-artifacts`. Off is an `emptyDir`, so prepared downloads go with the pod |
| `persistence.catalogSeeds` | `{}` | A volume source for `/catalog-seeds`, read-only |

### Pod and Service

| Value | Default | Description |
|---|---|---|
| `resources` | `{}` | Container resources. GPU transcoding takes a device plugin's resource in `limits`, such as `gpu.intel.com/i915: 1` or `nvidia.com/gpu: 1` |
| `pod.*` | | `annotations`, `labels` and `containerSecurityContext` are the chart's; anything else goes into the pod spec as written: `nodeSelector`, `tolerations`, `affinity`, `runtimeClassName: nvidia`, `hostNetwork` |
| `service.type`, `.port`, `.annotations`, `.labels`, `.loadBalancerIP`, `.externalTrafficPolicy` | `ClusterIP`, `80` | The Service |
| `httpRoute.enabled`, `.parentRefs`, `.annotations` | off | Gateway API routes. Enabling without a `parentRef` refuses to render |

## Hardware transcoding

Give the pod the GPU through its device plugin and the image finds it: `init-adduser` adds the `silo` account to the group of each device it is handed. A device owned by group 0 is skipped.

```yaml
resources:
  limits:
    gpu.intel.com/i915: 1
settings:
  SILO_HW_ACCEL: vaapi
  SILO_HW_DEVICE: /dev/dri/renderD128
```

For NVIDIA, request `nvidia.com/gpu`, set `pod.runtimeClassName: nvidia` if your cluster needs it, and add `NVIDIA_DRIVER_CAPABILITIES=all` through `env` so the NVENC libraries are mounted.

## Upgrades

Pin `image.tag`. An update restarts the pod (Recreate) and Silo migrates its database before listening again; the startup probe allows for that. A PostgreSQL major version change in the image needs a dump and restore, as upstream's release notes describe.
