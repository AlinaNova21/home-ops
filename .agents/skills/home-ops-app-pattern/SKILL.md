---
name: home-ops-app-pattern
description: Use when authoring a HelmRelease for an application using the bjw-s app-template chart - the standard chart shape used across all apps in the home-ops repository
---

# App Deployment Pattern (bjw-s app-template)

Every application in this repo uses the [bjw-s app-template](https://github.com/bjwjwj/helm-charts) chart. This skill documents the canonical shape.

## Chart reference

```yaml
spec:
  chart:
    spec:
      chart: app-template
      version: "4.5.0"   # pin explicitly
      sourceRef:
        kind: HelmRepository
        name: bjw-s
        namespace: flux-system
```

## Standard values structure

```yaml
spec:
  values:
    controllers:
      {app}:
        containers:
          {app}:
            image:
              repository: ...
              tag: ...
            env: ...
    service:
      {app}:
        controller: {app}
        ports:
          http:
            port: ...
    persistence:
      config:
        type: persistentVolumeClaim
        storageClass: ceph-rbd
```

## Conventions

- **`{app}`** is the controller/workload name (e.g. `sonarr-hd`, `plex`)
- **`storageClass`**: use `ceph-rbd` (primary, distributed) or `openebs-hostpath` (local, faster)
- **`image.tag`**: pin explicitly; Renovate manages updates via PR
- **`image.repository`**: full image path (e.g. `ghcr.io/linuxserver/sonarr`)
- **Service ports**: name them (`http`, not `80`); bjw-s template wires them up

## Common extras

```yaml
    # Probes
    containers:
      {app}:
        probes:
          liveness:
            tcpSocket:
              port: http
          readiness:
            tcpSocket:
              port: http

    # Resources (bjw-s uses simpleResources)
    resources:
      requests:
        cpu: 100m
        memory: 128Mi
      limits:
        cpu: 1000m
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
