# MeTube Deployment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy MeTube (self-hosted YouTube/yt-dlp downloader) to `downloads`, add the `media-youtube` NFS share PV/PVC to both `entertainment` and `downloads`, and give Tunarr read access to it.

**Architecture:** Three changes, all in the existing GitOps tree: (1) append a `youtube` NFS PV/PVC block to both namespaces' `storage/config/nfs-volumes.yaml` (established per-namespace share pattern), (2) add a standard bjw-s app-template app `kubernetes/downloads/metube/` (ks.yaml + ocirepository + helmrelease + httproute + kustomization, no kopiur backup component), (3) add a `media-youtube` persistence entry to Tunarr's HelmRelease. No new workflows, no secrets, no CRDs.

**Tech Stack:** Flux CD (Kustomization/HelmRelease/OCIRepository), bjw-s app-template v5.1.0 (OCI chart, cosign-verified), NFS PV/PVC, Envoy Gateway HTTPRoute (internal gateway `whoverse.dev`), `flate` + pre-commit validation.

**Design ref:** `docs/superpowers/specs/2026-09-11-metube-deployment-design.md`

---

## File Map

| File | Action |
|---|---|
| `kubernetes/entertainment/storage/config/nfs-volumes.yaml` | Modify — append `media-youtube-entertainment` PV + `media-youtube` PVC |
| `kubernetes/downloads/storage/config/nfs-volumes.yaml` | Modify — append `media-youtube-downloads` PV + `media-youtube` PVC |
| `kubernetes/downloads/metube/ks.yaml` | Create |
| `kubernetes/downloads/metube/app/ocirepository.yaml` | Create |
| `kubernetes/downloads/metube/app/helmrelease.yaml` | Create |
| `kubernetes/downloads/metube/app/httproute.yaml` | Create |
| `kubernetes/downloads/metube/app/kustomization.yaml` | Create |
| `kubernetes/downloads/kustomization.yaml` | Modify — add `- metube/ks.yaml` |
| `kubernetes/entertainment/tunarr/app/helmrelease.yaml` | Modify — add `media-youtube` persistence entry |
| `.github/renovate.json` | **Not touched** (see spec Renovate note) |

---

### Task 0: Worktree + baseline

**Files:** none

- [ ] **Step 1: Create the implementation worktree**

The docs branch already holds the spec/plan (PR #951). Implementation goes in a `feat/metube` branch per repo precedent:

Run (from repo root):
```bash
just worktree-create feat/metube
cd .worktrees/feat/metube
mise install
mise run secrets:env    # regenerate .env; skip if no `op` session
```

- [ ] **Step 2: Baseline validation**

Run: `just flate-test`
Expected: PASS (or report the failures before proceeding).

---

### Task 1: Add `media-youtube` share PV/PVC to both storage configs

**Files:**
- Modify: `kubernetes/entertainment/storage/config/nfs-volumes.yaml` (append at end)
- Modify: `kubernetes/downloads/storage/config/nfs-volumes.yaml` (append at end)

- [ ] **Step 1: Append to `kubernetes/entertainment/storage/config/nfs-volumes.yaml`**

Append this block (mirrors the existing `media-tv-old` block exactly, with the youtube path):

```yaml
---
# YouTube (entertainment namespace)
apiVersion: v1
kind: PersistentVolume
metadata:
  name: media-youtube-entertainment
spec:
  capacity:
    storage: 1Ti
  accessModes:
    - ReadWriteMany
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ""
  nfs:
    server: 192.168.2.193
    path: /mnt/tank/media/youtube
  mountOptions:
    - nfsvers=4
    - nolock
    - soft
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: media-youtube
  namespace: entertainment
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: ""
  volumeName: media-youtube-entertainment
  resources:
    requests:
      storage: 1Ti
```

- [ ] **Step 2: Append to `kubernetes/downloads/storage/config/nfs-volumes.yaml`**

Identical block but PV name `media-youtube-downloads`; other fields identical:

```yaml
# YouTube (downloads namespace)
apiVersion: v1
kind: PersistentVolume
metadata:
  name: media-youtube-downloads
spec:
  capacity:
    storage: 1Ti
  accessModes:
    - ReadWriteMany
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ""
  nfs:
    server: 192.168.2.193
    path: /mnt/tank/media/youtube
  mountOptions:
    - nfsvers=4
    - nolock
    - soft
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: media-youtube
  namespace: downloads
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: ""
  volumeName: media-youtube-downloads
  resources:
    requests:
      storage: 1Ti
```

- [ ] **Step 3: Validate**

```bash
just flate-test
```

Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add kubernetes/entertainment/storage/config/nfs-volumes.yaml kubernetes/downloads/storage/config/nfs-volumes.yaml
git commit -m "feat(storage): add media-youtube NFS share PVCs to entertainment and downloads"
```

---

## Task 2: MeTube app manifests (`kubernetes/downloads/metube/`)

**Files:**
- Create: `kubernetes/downloads/metube/ks.yaml`
- Create: `kubernetes/downloads/metube/app/ocirepository.yaml`
- Create: `kubernetes/downloads/metube/app/helmrelease.yaml`
- Create: `kubernetes/downloads/metube/app/httproute.yaml`
- Create: `kubernetes/downloads/metube/app/kustomization.yaml`

- [ ] **Step 1: Create `kubernetes/downloads/metube/ks.yaml`** (Flux Kustomization; no `components:` — no kopiur backup since the only persistent data is on the NFS share)

```yaml
---
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/kustomize.toolkit.fluxcd.io/kustomization_v1.json
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: metube
  namespace: downloads
spec:
  targetNamespace: downloads
  interval: 15m
  path: "./kubernetes/downloads/metube/app"
  sourceRef:
    kind: GitRepository
    name: home-ops
    namespace: flux-system
  timeout: 10m
  wait: true
  prune: true
```

- [ ] **Step 2: Create `kubernetes/downloads/metube/app/ocirepository.yaml`** (app-template chart, same pin as tunarr, cosign-verified)

```yaml
---
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/source.toolkit.fluxcd.io/ocirepository_v1.json
apiVersion: source.toolkit.fluxcd.io/v1
kind: OCIRepository
metadata:
  name: metube
  namespace: downloads
spec:
  interval: 1h
  layerSelector:
    mediaType: application/vnd.cncf.helm.chart.content.v1.tar+gzip
    operation: copy
  ref:
    tag: "5.1.0"
    digest: sha256:0d039f7760db66790168e9de13780327ad1adecca0a3b31621e32146d8be503c
  url: oci://ghcr.io/bjw-s-labs/helm/app-template
  verify:
    provider: cosign
    matchOIDCIdentity:
      - issuer: ^https://token.actions.githubusercontent.com$
        subject: ^https://github.com/bjw-s-labs/helm-charts/.github/workflows/chart-release-steps.yaml#@.*$
```

- [ ] **Step 3: Create `kubernetes/downloads/metube/app/helmrelease.yaml`**

Run `crane digest ghcr.io/alexta69/metube:2026.08.28` and paste its output verbatim into the `tag:` below (do not retype). Reference value: `sha256:397778fccf13d83adf9325fe813b260617a082d1772aff6d678c5b9256dd01fb`.

```yaml
---
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/helm.toolkit.fluxcd.io/helmrelease_v2.json
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: metube
  namespace: downloads
spec:
  interval: 15m
  chartRef:
    kind: OCIRepository
    name: metube
    namespace: downloads
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
    defaultPodOptions:
      affinity:
        nodeAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100
              preference:
                matchExpressions:
                  - key: kubernetes.io/hostname
                    operator: In
                    values:
                      - whoverse-w1
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
              tag: 2026.08.28@sha256:397778fccf13d83adf9325fe813b260617a082d1772aff6d2c5b9256dd01fb
            env:
              TZ: "America/Chicago"
              CHOWN_DIRS: "false"
            probes:
              liveness:
                enabled: true
                custom: true
                spec:
                  httpGet:
                    path: /
                    port: http
                  initialDelaySeconds: 20
                  periodSeconds: 10
                  failureThreshold: 3
              readiness:
                enabled: true
                custom: true
                spec:
                  httpGet:
                    path: /
                    port: http
                  initialDelaySeconds: 20
                  periodSeconds: 10
                  failureThreshold: 3
            resources:
              requests:
                cpu: 100m
                memory: 256Mi
              limits:
                memory: 2Gi
    service:
      metube:
        controller: metube
        ports:
          http:
            port: 8081
    persistence:
      downloads:
        type: persistentVolumeClaim
        existingClaim: media-youtube
        globalMounts:
          - path: /downloads
```

- [ ] **Step 4: Create `kubernetes/downloads/metube/app/httproute.yaml`** (internal-only, per `home-ops-create-httproute`)

```yaml
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: metube
  namespace: downloads
spec:
  parentRefs:
    - name: internal
      namespace: network
  hostnames:
    - "metube.whoverse.dev"
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: metube
          port: 8081
```

- [ ] **Step 5: Create `kubernetes/downloads/metube/app/kustomization.yaml`**

```yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ocirepository.yaml
  - helmrelease.yaml
  - httproute.yaml
```

- [ ] **Step 6: Register the component in `kubernetes/downloads/kustomization.yaml`**

Add `- metube/ks.yaml` to the resources list (after `- sabnzbd/ks.yaml`, keeping downloaders together):

```yaml
resources:
  - ns.yaml
  - storage/ks.yaml
  - profilarr/ks.yaml
  - prowlarr/ks.yaml
  - sabnzbd/ks.yaml
  - metube/ks.yaml
  - radarr-hd/ks.yaml
  ...
```

- [ ] **Step 7: Validate**

```bash
pre-commit run --all-files   # gitleaks + trufflehog
just flate-test --allow-missing-secrets
```

Expected: all pass. If `just flate-test` fails on the brand-new dir (known worktree+new-dir caveat — flate materializes `home-ops` from origin/main), the authoritative check is CI on the PR head.

- [ ] **Step 8: Commit**

```bash
git add kubernetes/downloads/metube/ kubernetes/downloads/kustomization.yaml
git commit -m "feat(downloads): add metube app"
```

---

## Task 3: Tunarr mount `media-youtube`

**Files:**
- Modify: `kubernetes/entertainment/tunarr/app/helmrelease.yaml` (persistence section)

- [ ] **Step 1: Add the persistence entry**

In `spec.values.persistence`, after the `media-tv-old:` entry, add:

```yaml
      media-youtube:
        type: persistentVolumeClaim
        existingClaim: media-youtube
        globalMounts:
          - path: /data/youtube
```

- [ ] **Step 2: Validate**

```bash
pre-commit run --all-files
just flate-test --allow-missing-secrets
```

Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add kubernetes/entertainment/tunarr/app/helmrelease.yaml
git commit -m "feat(entertainment): mount media-youtube share in tunarr"
```

---

## Task 4: Landing

**Files:** none

- [ ] **Step 1: Full validation** (must pass before push)

```bash
cd /home/alina/projects/home-ops/.worktrees/feat/metube
pre-commit run --all-files
just flate-test --allow-missing-secrets
```

Record the output. Note the brand-new-dir caveat if flate complains.

- [ ] **Step 2: Push + PR**

```bash
git push -u origin feat/metube
gh pr create --fill
```

PR description: point at spec (`docs/superpowers/specs/2026-09-11-metube-deployment-design.md`) and list the three change areas; note that after merge the user registers `/data/youtube` in Tunarr's UI.

- [ ] **Step 3: Cleanup docs worktree** (after PR #951 and the feat PR are mergeable)

```bash
cd /home/alina/projects/home-ops
just worktree-clean docs/metube-deployment-design
just worktree-clean feat/metube
```

## Post-deploy verification (manual, after merge)

```bash
kubectl get pv media-youtube-entertainment media-youtube-downloads        # Bound
kubectl get pods -n downloads -l app.kubernetes.io/name=metube            # Running
kubectl exec -n downloads deploy/metube -- ls /downloads                  # share mounted, uid 1000
curl -s http://metube.whoverse.dev                                          # via Tailscale/gateway
```

Also confirm in the tun arr UI that `/data/youtube` mounts as a library path for channels.