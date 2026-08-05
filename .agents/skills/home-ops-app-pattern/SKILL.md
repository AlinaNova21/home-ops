---
name: home-ops-app-pattern
description: Use when authoring a HelmRelease for an application in the home-ops repository - the standard OCI chartRef + bjw-s app-template values shape used across all apps
---

# App Deployment Pattern (bjw-s app-template via OCI)

Every application in this repo runs the [bjw-s app-template](https://github.com/bjw-s-labs/helm-charts) chart, delivered as an **OCI chart** (`helm.toolkit.fluxcd.io/v2` + `chartRef`). No HelmRepository chart sources for apps — charts come from `ghcr.io/bjw-s-labs/helm/app-template` with cosign signature verification.

## Chart source — `app/ocirepository.yaml`

Each app pins its own `OCIRepository` (same namespace as the app):

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: OCIRepository
metadata:
  name: {app}
  namespace: {namespace}
spec:
  interval: 1h
  layerSelector:
    mediaType: application/vnd.cncf.helm.chart.content.v1.tar+gzip
    operation: copy
  ref:
    tag: "5.0.1"          # pin explicitly (Renovate updates via PR)
    digest: sha256:...    # pin digest
  url: oci://ghcr.io/bjw-s-labs/helm/app-template
  verify:
    provider: cosign
    matchOIDCIdentity:
      - issuer: ^https://token.actions.githubusercontent.com$
        subject: ^https://github.com/bjw-s-labs/helm-charts/.github/workflows/chart-release-steps.yaml@.*$
```

## HelmRelease — `app/helmrelease.yaml`

```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: {app}
  namespace: {namespace}
spec:
  interval: 30m
  chartRef:
    kind: OCIRepository
    name: {app}            # matches the OCIRepository above, same namespace
    namespace: {namespace}
  install:
    createNamespace: false
    remediation:
      retries: 3
    strategy:
      name: RetryOnFailure
      retryInterval: 5m
  upgrade:
    remediation:
      retries: 3
    strategy:
      name: RetryOnFailure
      retryInterval: 5m
  values:
    ...
```

**Standard values structure** (bjw-s app-template v4 shape):

```yaml
spec:
  values:
    controllers:
      {app}:
        containers:
          {app}:
            image:
              repository: ghcr.io/linuxserver/sonarr
              tag: ...        # pin explicitly
            env:
              TZ: America/Chicago
    service:
      {app}:
        controller: {app}
        ports:
          http:
            port: 80
    persistence:
      config:
        type: persistentVolumeClaim
        accessMode: ReadWriteOnce
        size: 1Gi
        dataSourceRef:
          apiGroup: kopiur.home-operations.com
          kind: Restore
          name: {app}
```

## Conventions

- **`{app}`** is the controller/workload name (e.g. `sonarr-hd`, `plex`)
- **`image.tag`**: pin explicitly (digest or tag); Renovate manages updates via PR
- **`image.repository`**: full image path
- **Service ports**: name them (`http`, not `80`)
- **storageClass**: use `miroir-replicated` (default SC) or `miroir-local`; do NOT reference `ceph-rbd`/`openebs-hostpath` — rook-ceph and openebs-localpv are disabled. Only set `storageClass` when you need a non-default class; the cluster default (`miroir-replicated`) applies otherwise.
- **Backup persistence**: apps with PVCs use the kopiur `Restore` populator via `dataSourceRef` (as above) — added automatically when the `ks.yaml` includes the `kopiur/backup` component (see `home-ops-add-new-app`). Jellyfin uses an NFS `cache` volume (`type: nfs`, `globalMounts`) in addition — see its `helmrelease.yaml` for the shape.

## Common extras

```yaml
    # Probes
    controllers:
      {app}:
        containers:
          {app}:
            probes:
              liveness:
                tcpSocket:
                  port: http
              readiness:
                tcpSocket:
                  port: http

    # Resources
    resources:
      requests:
        cpu: 100m
        memory: 128Mi
      limits:
        memory: 512Mi

    # ServiceAccount / RBAC
    serviceAccount:
      create: true
```

## Pod security context — match the image, not the *arr default

Most LinuxServer.io images run as UID/GID `1000:1000` and the *arr cluster convention
in this repo mirrors that. **Not every image does.** For non-LSI images (or anything
migrating from existing data), discover the actual user before picking UID/GID:

```bash
# From the source host (Docker bind-mount, host dir, etc.)
stat -c 'uid=%u gid=%g %n' /path/to/data/{,.env,version.json,artisan}

# From the running container
docker exec {container} id
docker exec {container} stat -c 'uid=%u gid=%g' /path/to/image-layer/file
```

Then declare the matching securityContext on the workload:

```yaml
    defaultPodOptions:
      securityContext:
        runAsUser: 100       # matches image USER + data file owner
        runAsGroup: 101
        fsGroup: 101         # lets fsGroup see group-readable data files
        fsGroupChangePolicy: "OnRootMismatch"
```

If `runAsUser` doesn't match, entrypoint scripts with `set -eu` abort on the first
permission-denied write and the container CrashLoopBackOffs before the app starts.
This is the #1 cause of "works in docker, fails in k8s" migrations.

**Kopiur `Restore` mover** must use the same UID/GID as the data it writes back, so the
freshly-restored PVC files match what the running container expects to read:

```yaml
spec:
  mover:
    securityContext:
      runAsUser: 100
      runAsGroup: 101
    podSecurityContext:
      fsGroup: 101
```

## See also

- `home-ops-add-new-app` — full workflow for adding a new app
- `home-ops-create-httproute` — for ingress wiring
- `home-ops-external-secrets` — for secret syncing
