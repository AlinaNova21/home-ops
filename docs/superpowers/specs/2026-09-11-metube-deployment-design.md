# MeTube Deployment Design

**Date:** 2026-09-11
**Status:** Approved (design review)
**Scope:** Deploy [MeTube](https://github.com/alexta69/metube) (self-hosted YouTube/yt-dlp downloader UI) to the `downloads` namespace, add the new NAS `youtube` NFS share to the media share PVs in both namespaces, and give Tunarr read access to it.

## Background

MeTube is a self-hosted web UI for `yt-dlp`: download videos/audio/captions/playlists from YouTube and dozens of other sites, with optional channel/playlist **subscriptions** that periodically check for new uploads and queue them automatically. The image publishes a new release on every yt-dlp stable release, so it updates frequently.

Decisions confirmed with the user:

- **Namespace:** `downloads` (alongside sabnzbd and the *arr stack).
- **Ingress:** internal gateway only (`metube.whoverse.dev`) — MeTube's API is unauthenticated; internal-only matches the existing posture of sabnzbd/seerr.
- **State location:** on the NAS share (image default `/downloads/.metube`), snapshot-backed by the tank; **no** kopiur-backed PVC for state. Changeable later if desired.
- **UID/GID:** 1000, matching the NAS share ownership and the rest of the NFS-mounted media apps.
- **Approach:** direct-to-share (A) — MeTube writes to the share root; Tunarr mounts the same claim read-side.

## Goals

1. Add `media-youtube` NFS share PV/PVC to **both** `entertainment` and `downloads` storage configs (the established per-namespace media-share pattern).
2. Deploy MeTube in `downloads`, mounting `media-youtube` at its default `/downloads`, exposed internally only.
3. Mount `media-youtube` in Tunarr (`entertainment`) at `/data/youtube` so channels can include the downloaded content.
4. Pass the standard validation gates (`flate-test`, pre-commit) and land via PR.

## Non-goals

- External (Cloudflare) exposure + OIDC auth — deferred; internal-only for now, the yuvomi/trilium auth pattern exists if we want it later.
- YouTube cookies / age-restricted content — uploadable from the MeTube UI at any time; no ExternalSecret needed now.
- Initial `YTDL_OPTIONS` / presets — defaults; tune via UI later.
- Renovate rule changes — metube keeps its date-based tag scheme flowing through the generic `flux` manager (see [Renovate](#renovate-consideration)).

## Current State

### Media share pattern

Every NAS media share is duplicated in each namespace that consumes it: `kubernetes/{ns}/storage/config/nfs-volumes.yaml` defines a PV named `media-<sub>-<namespace>` + a PVC named `media-<sub>` in that namespace, pointing at `192.168.2.193:/mnt/tank/media/<sub>` (RWX, Retain, 1Ti, mountOptions `nfsvers=4`/`nolock`/`soft`). Apps consume via `persistence: {name}: {type: persistentVolumeClaim, existingClaim: media-<sub>, globalMounts: [{path: /data/...}]}`.

`entertainment` and `downloads` both currently carry `media-music`, `media-movies-{anime,hd,uhd}`, `media-tv-{anime,hd,kids,old}`. Tunarr mounts all of them.

### MeTube facts

- Image `ghcr.io/alexta69/metube`, default port `8081` (WebSocket for live UI updates — Envoy Gateway handles this natively).
- Default `DOWNLOAD_DIR=/downloads`; state files (`queue.json`, `pending.json`, `completed.json`, `subscriptions.json`) at `STATE_DIR=/downloads/.metube` (dot-dir, auto-excluded from the UI folder chooser via `CUSTOM_DIRS_EXCLUDE_REGEX`).
- Runs as default `PUID=1000`/`PGID=1000`; `CHOWN_DIRS=true` default (chowns DOWNLOAD_DIR/STATE_DIR/TEMP_DIR on start).
- Tags are date-based (`2026.08.28`), published frequently.

## Design

### 1. Share PVCs (`media-youtube`)

Add a `youtube` entry to both storage configs, mirroring the existing blocks exactly:

**`kubernetes/entertainment/storage/config/nfs-volumes.yaml`** (for Tunarr)

```yaml
# YouTube (entertainment namespace)
apiVersion: v1
kind: PersistentVolume
metadata:
  name: media-youtube-entertainment
spec:
  capacity: { storage: 1Ti }
  accessModes: [ReadWriteMany]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ""
  nfs:
    server: 192.168.2.193
    path: /mnt/tank/media/youtube
  mountOptions: [nfsvers=4, nolock, soft]
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: media-youtube
  namespace: entertainment
spec:
  accessModes: [ReadWriteMany]
  storageClassName: ""
  volumeName: media-youtube-entertainment
  resources: { requests: { storage: 1Ti } }
```

**`kubernetes/downloads/storage/config/nfs-volumes.yaml`** — identical, with PV `media-youtube-downloads` and PVC `media-youtube` in `downloads`.

### 2. MeTube app (`kubernetes/downloads/metube/`)

Standard bjw-s app-template v5.1.0 OCI app (same chart pin as Tunarr, verified by cosign OIDC identity), no kopiur backup component (no own PVC — state lives on the share).

Files per `home-ops-add-new-app`:
- `ks.yaml` — Flux Kustomization (`targetNamespace: downloads`, no `components:` — no kopiur backup needed; interval 15m, wait, prune).
- `app/ocirepository.yaml` — app-template chart, pin `tag: 5.1.0` + digest (copied from Tunarr's current pin).
- `app/helmrelease.yaml` — key values:

```yaml
values:
  defaultPodOptions:
    affinity:
      nodeAffinity:
        preferredDuringSchedulingIgnoredDuringExecution:
          - weight: 100
            preference:
              matchExpressions:
                - key: kubernetes.io/hostname
                  operator: In
                  values: [whoverse-w1]     # match sabnzbd's preferred scheduling
    securityContext:
      runAsUser: 1000
      runAsGroup: 1000
      fsGroup: 1000
  controllers:
    metube:
      strategy: Recreate
      containers:
        metube:
          image:
            repository: ghcr.io/alexta69/metube
            tag: 2026.08.28@sha256:397778fccf13d83adf9325fe813b260617a082d1772aff6d678c5b9256dd01fb  # latest at design time
          env:
            TZ: America/Chicago
            CHOWN_DIRS: "false"   # share ownership already == 1000; avoid full-share recursive chown on every start
          probes:
            liveness:  { httpGet: { path: /, port: http }, initialDelaySeconds: 20, periodSeconds: 10 }
            readiness: { httpGet: { path: /, port: http }, initialDelaySeconds: 20, periodSeconds: 10 }
          resources:
            requests: { cpu: 100m, memory: 256Mi }
            limits:   { memory: 2Gi }        # yt-dlp + ffmpeg can spike; generous limit
  service:
    metube:
      controller: metube
      ports: { http: { port: 8081 } }
  persistence:
    downloads:
      type: persistentVolumeClaim
      existingClaim: media-youtube
      globalMounts: [{ path: /downloads }]
```

Notes:
- `securityContext.runAsUser/Group 1000` matches the confirmed NAS share ownership; `fsGroup` is inert on NFS but kept for consistency with the *arr convention.
- No `PUID`/`PGID` env needed (securityContext already fixes users); `CHOWN_DIRS=false` avoids a recursive chown of the whole share at each pod start (slow once the library grows).
- `TEMP_DIR` default is `/downloads` — acceptable on NFS here (low-volume; option for SSD/tmpfs is documented and reversible later).

- `app/httproute.yaml` — internal-only:

```yaml
parentRefs:
  - name: internal
    namespace: network
hostnames: ["metube.whoverse.dev"]
rules:
  - matches: [{ path: { type: PathPrefix, value: / } }]
    backendRefs: [{ name: metube, port: 8081 }]
```

- `app/kustomization.yaml` — resources: `ocirepository.yaml`, `helmrelease.yaml`, `httproute.yaml`.
- Register `metube/ks.yaml` in `kubernetes/downloads/kustomization.yaml`.

### 3. Tunarr mount

`kubernetes/entertainment/tunarr/app/helmrelease.yaml` — add a persistence entry alongside the existing media mounts:

```yaml
media-youtube:
  type: persistentVolumeClaim
  existingClaim: media-youtube
  globalMounts:
    - path: /data/youtube
```

Post-deploy manual step (documented in the plan): the user registers `/data/youtube` as a library in the Tunarr UI.

## Validation

- Baseline `just flate-test` in the worktree before changes; `pre-commit run --all-files` + `just flate-test --allow-missing-secrets` before commit. Note the known caveat that `flate-test` can fail on brand-new dirs in a worktree (flate materializes the `home-ops` GitRepository source from `origin/main`), so a failing local `flate-test` on new files doesn't block — CI on the PR head is authoritative.
- `just flate-diff` / CI `validate-kubernetes.yml` confirms nothing else drifts.
- After merge: `kubectl get pv media-youtube-{entertainment,downloads}`, pod logs show metube serving on 8081, and Tunarr sees the folder.

## Renovate consideration

metube tags are date-based (`2026.08.28`). The default `flux` manager should pick them up as Docker dep updates, but date-based versioning may churn or mis-sort. If that shows up in review, add a docker `versioning` override for `ghcr.io/alexta69/metube` in `.github/renovate.json` as a follow-up (explicitly out of scope for this change).