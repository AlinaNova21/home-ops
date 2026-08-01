# zot OCI Registry — Design Spec

**Date:** 2025-08-01
**Status:** Draft
**Namespace:** `storage/`
**Access:** internal only (`*.whoverse.dev`)

---

## Context

Spegel handles public OCI registry caching (ghcr.io, quay.io, etc.) as a P2P layer in front of containerd. This cluster has no persistent local OCI registry for private/homelab images (custom builds, internal helm charts, etc.).

**Goal:** Deploy zot as a local, persistent OCI registry for images that don't belong on public registries. No upstream sync — Spegel and zot serve different purposes and don't overlap.

---

## Architecture

```
containerd (pulls images)
    ├── → zot.whoverse.dev (local private images)
    └── → Spegel → upstream internet (public images)

Spegel (pulls upstream, caches blobs)
zot (hosts local images, receives pushes from local builds)
```

Both registries coexist independently. No Spegel → zot integration.

---

## Components

### Namespace

No new namespace needed. zot lives alongside miroir in `storage/`.

### Storage

`miroir-replicated` PVC (pool: `replicated`, replicas: 2). Survives pod restarts.

- `persistence: true`
- `persistence.storageClassName: miroir-replicated`
- `persistence.storage: 8Gi` (adjustable)
- `strategy.type: Recreate` (required for local storage)

### Chart

- **URL:** `oci://ghcr.io/project-zot/helm-charts/zot`
- **Chart version:** `0.1.122` (pin with digest)
- **App version:** `v2.1.18`

### Service

`ClusterIP` (Envoy Gateway handles ingress). No NodePort.

### zot Config (`configFiles.config.json`)

```json
{
  "storage": {
    "rootDirectory": "/var/lib/registry",
    "readOnly": false
  },
  "http": {
    "address": "0.0.0.0",
    "port": "5000",
    "readTimeout": "60s",
    "writeTimeout": "60s"
  },
  "log": { "level": "info" }
}
```

- `readOnly: false` enables push (required for `readwrite` mode)
- No auth — internal network only; any pod can push/pull
- Log level `info` instead of `debug` (less noise)

### HTTPRoute

```yaml
parentRefs:
  - name: internal        # internal gateway (Tailscale LB)
    namespace: network
hostnames:
  - zot.whoverse.dev
backendRefs:
  - name: zot
    port: 5000
```

No external HTTPRoute (`.whoverse.nexus`) — this is internal-only.

### Probes

zot exposes standard Kubernetes probe endpoints on port 5000:
- `/startupz` — startup probe (chart default)
- `/livez` — liveness probe (chart default)
- `/readyz` — readiness probe (chart default)

No auth required on probe paths. `httpGet.scheme: HTTP` (chart default).

### ServiceMonitor

Enabled for Prometheus scraping (matches existing monitoring stack).

---

## File Structure

```
kubernetes/storage/
├── zot/
│   ├── app/
│   │   ├── ocirepository.yaml   # Flux OCIRepository (pinned digest)
│   │   ├── helmrelease.yaml     # HelmRelease (chart + values)
│   │   ├── httproute.yaml       # Gateway API HTTPRoute
│   │   └── kustomization.yaml   # kustomization (refs ns.yaml first)
│   └── ks.yaml                  # Flux Kustomization (namespace: storage)
└── kustomization.yaml           # storage namespace aggregator (add zot/)
```

---

## Interactions

| Component | Interaction |
|---|---|
| containerd | Pulls from `zot.whoverse.dev` (add to hosts or cri registry config) |
| Local builds | Push to `zot.whoverse.dev` via `docker` or `oras` |
| Spegel | No interaction — separate layer |
| Envoy Gateway (internal) | Routes `zot.whoverse.dev:443` → zot:5000 |
| external-dns-dev | Picks up HTTPRoute, creates DNS record automatically |

---

## Trade-offs

| Decision | Why |
|---|---|
| No auth | Internal LAN behind Tailscale auth + gateway; adds friction for no benefit |
| `miroir-replicated` (2 replicas) | Data survives node failure + pod restart |
| `strategy.type: Recreate` | Required when using local storage (can't have two pods writing same volume) |
| No external route | Private images shouldn't be exposed publicly; `spegel` handles public pulls |

---

## Verification

```bash
# 1. Build and push a test image
docker build -t zot.whoverse.dev/test:latest .
docker push zot.whoverse.dev/test:latest

# 2. Pull from a pod (after updating containerd registry config)
kubectl run test-pull --rm -it --image=zot.whoverse.dev/test:latest

# 3. Check HTTPRoute status
kubectl get httproute zot -n storage

# 4. Check PVC bound
kubectl get pvc -n storage -l app.kubernetes.io/name=zot
```

---

## TODO

- [ ] Add containerd registry config pointing to `zot.whoverse.dev` (updates Spegel or creates new hosts config)
- [ ] Decide initial storage size (default 8Gi, confirm sufficient)
- [ ] Confirm whether `ks.yaml` needs `spec.postBuild.substitute` for the storage PVC name
