# silo-charts

Helm charts for [Silo](https://github.com/Silo-Server/silo-server), the self-hosted media server.

| Chart | What it runs | Pick it when |
|---|---|---|
| [`silo-omnibus`](charts/silo-omnibus) | One pod of Silo's all-in-one image, with its bundled PostgreSQL, Redis and Meilisearch, exactly as upstream's `docker-compose.yml` runs it | You want one server, the upstream-supported layout, and one volume to back up |
| [`silo`](charts/silo) | Only Silo, split into its parts: API servers and optional proxy (stream egress) and transcode nodes. You bring PostgreSQL, Redis and Meilisearch | You already run databases in the cluster, want to scale playback across nodes, or want GPUs on specific machines |

Both charts use the same image, `ghcr.io/silo-server/silo-server`, and follow the same conventions: you create the Secrets, nothing credential-shaped goes in `values.yaml`, media is mounted from a volume source you already have, and Gateway API `HTTPRoute`s are the way in.

```sh
kubectl create secret generic silo --from-literal SECRET_KEY="$(openssl rand -base64 48)"
helm install silo charts/silo-omnibus \
  --set hostname=silo.example.com \
  --set-json 'media.volume={"persistentVolumeClaim":{"claimName":"media"}}'
```

Back `SECRET_KEY` up apart from your database. Silo encrypts stored credentials under it, and nothing can recover them once it is lost.

Run `./ci/test-charts.sh` to lint and render both charts the way CI does.
