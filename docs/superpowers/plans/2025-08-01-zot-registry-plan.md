# zot OCI Registry — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy zot as a local OCI registry in the `storage/` namespace, backed by `miroir-replicated` PVC, accessible via `zot.whoverse.dev` on the internal Tailscale gateway.

**Architecture:** Single StatefulSet with `miroir-replicated` PVC, ClusterIP service, Gateway API HTTPRoute on the internal Envoy gateway. Flux manages the HelmRelease via OCIRepository.

**Tech Stack:** Flux CD (HelmRelease + OCIRepository), Gateway API (HTTPRoute), project-zot helm chart (OCI), miroir-replicated storage.

---

## File Map

```
kubernetes/storage/zot/
├── app/
│   ├── ocirepository.yaml    # Flux OCIRepository (chart source)
│   ├── helmrelease.yaml      # HelmRelease + zot config values
│   ├── httproute.yaml        # Gateway API HTTPRoute (internal gateway)
│   └── kustomization.yaml    # kustomization (refs ns.yaml first)
└── ks.yaml                   # Flux Kustomization (reconciles ./app)

kubernetes/storage/kustomization.yaml   # MODIFY — add zot/ to resources
```

---

## Tasks

### Task 1: Create directory structure and `ocirepository.yaml`

**Files:**
- Create: `kubernetes/storage/zot/app/ocirepository.yaml`

- [ ] **Step 1: Create directory and ocirepository.yaml**

```bash
mkdir -p kubernetes/storage/zot/app
```

```yaml
# kubernetes/storage/zot/app/ocirepository.yaml
---
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/source.toolkit.fluxcd.io/ocirepository_v1.json
apiVersion: source.toolkit.fluxcd.io/v1
kind: OCIRepository
metadata:
  name: zot
  namespace: storage
spec:
  interval: 1h
  layerSelector:
    mediaType: application/vnd.cncf.helm.chart.content.v1.tar+gzip
    operation: copy
  ref:
    tag: 0.1.122
    digest: sha256:e5fc104e1225de17ac9b0deb387ad1d4ad2794415122f4407848b4c82f066ecc
  url: oci://ghcr.io/project-zot/helm-charts/zot
```

Digest confirmed: `sha256:e5fc104e...`. Re-verify with `crane digest ghcr.io/project-zot/helm-charts/zot:0.1.122`.

---

### Task 2: Create `helmrelease.yaml`

**Files:**
- Create: `kubernetes/storage/zot/app/helmrelease.yaml`

- [ ] **Step 1: Write helmrelease.yaml**

```yaml
# kubernetes/storage/zot/app/helmrelease.yaml
---
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/helm.toolkit.fluxcd.io/helmrelease_v2.json
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: zot
  namespace: storage
spec:
  interval: 30m
  chartRef:
    kind: OCIRepository
    name: zot
    namespace: storage
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
    replicaCount: 1
    image:
      repository: ghcr.io/project-zot/zot
      tag: "v2.1.18"
    service:
      type: ClusterIP
      port: 5000
    httpGet:
      scheme: HTTP
      port: 5000
    startupProbe:
      initialDelaySeconds: 5
      periodSeconds: 10
      failureThreshold: 30
    configFiles:
      config.json: |-
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
    persistence:
      enabled: true
      storageClassName: miroir-replicated
      storage: 8Gi
      create: true
      accessModes: ["ReadWriteOnce"]
    strategy:
      type: Recreate
    metrics:
      enabled: true
      serviceMonitor:
        enabled: true
    serviceAccount:
      create: true
```

---

### Task 3: Create `httproute.yaml`

**Files:**
- Create: `kubernetes/storage/zot/app/httproute.yaml`

- [ ] **Step 1: Write httproute.yaml**

```yaml
# kubernetes/storage/zot/app/httproute.yaml
---
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/gateway.networking.k8s.io/httproute_v1.json
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: zot
  namespace: storage
spec:
  parentRefs:
    - name: internal
      namespace: network
  hostnames:
    - "zot.whoverse.dev"
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: zot
          port: 5000
```

---

### Task 4: Create `kustomization.yaml`

**Files:**
- Create: `kubernetes/storage/zot/app/kustomization.yaml`

- [ ] **Step 1: Write kustomization.yaml**

```yaml
# kubernetes/storage/zot/app/kustomization.yaml
---
# yaml-language-server: $schema=https://json.schemastore.org/kustomization
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - helmrelease.yaml
  - ocirepository.yaml
  - httproute.yaml
```

Note: Do NOT reference `ns.yaml` from a component kustomization.

---

### Task 5: Create `ks.yaml`

**Files:**
- Create: `kubernetes/storage/zot/ks.yaml`

- [ ] **Step 1: Write ks.yaml**

Pattern matches `kubernetes/storage/miroir/ks.yaml`.

```yaml
# kubernetes/storage/zot/ks.yaml
---
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/kustomize.toolkit.fluxcd.io/kustomization_v1.json
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: zot
  namespace: storage
spec:
  interval: 30m
  path: "./kubernetes/storage/zot/app"
  sourceRef:
    kind: GitRepository
    name: home-ops
    namespace: flux-system
  healthChecks:
    - apiVersion: helm.toolkit.fluxcd.io/v2
      kind: HelmRelease
      name: zot
      namespace: storage
  timeout: 10m
  wait: true
  prune: true
```

---

### Task 6: Update storage namespace aggregator

**Files:**
- Modify: `kubernetes/storage/kustomization.yaml`

- [ ] **Step 1: Read current storage/kustomization.yaml**

```bash
cat kubernetes/storage/kustomization.yaml
```

Expected output:
```yaml
resources:
  - miroir
  - ns.yaml
```

- [ ] **Step 2: Add zot to resources**

```yaml
resources:
  - miroir
  - zot
  - ns.yaml
```

---

### Task 7: Verify OCIRepository digest

**Files:**
- Modify: `kubernetes/storage/zot/app/ocirepository.yaml` (digest field, if needed)

- [ ] **Step 1: Verify zot chart digest**

Digest was confirmed at plan-writing time:
```
sha256:e5fc104e1225de17ac9b0deb387ad1d4ad2794415122f4407848b4c82f066ecc
```

To re-verify:
```bash
crane digest ghcr.io/project-zot/helm-charts/zot:0.1.122
```

If the digest differs, update `kubernetes/storage/zot/app/ocirepository.yaml` before committing.

---

### Task 8: Validate and commit

**Files modified/created:**
- `kubernetes/storage/zot/app/ocirepository.yaml` (create)
- `kubernetes/storage/zot/app/helmrelease.yaml` (create)
- `kubernetes/storage/zot/app/httproute.yaml` (create)
- `kubernetes/storage/zot/app/kustomization.yaml` (create)
- `kubernetes/storage/zot/ks.yaml` (create)
- `kubernetes/storage/kustomization.yaml` (modify)

- [ ] **Step 1: Run pre-commit validation**

```bash
SKIP=gitleaks,trufflehog pre-commit run --all-files
```

Expected: PASS

- [ ] **Step 2: Run flate validation**

```bash
just flate-test
```

Expected: PASS

- [ ] **Step 3: Commit**

```bash
git add kubernetes/storage/zot/ kubernetes/storage/kustomization.yaml
git commit -m "feat(storage): add zot OCI registry at zot.whoverse.dev"
```

---

## Post-Commit (Day-2)

Optional verification steps — zot is fully configured by this plan:

1. **Verify Flux reconciliation** — after push to main, confirm zot deploys:
   ```bash
   flux reconcile kustomization cluster -n flux-system
   kubectl get hr,zot,pvc -n storage  # should show zot HelmRelease, deployment, PVC
   kubectl get httproute zot -n storage
   ```

2. **Push a test image** — verify push works:
   ```bash
   docker build -t zot.whoverse.dev/test:latest .
   docker login zot.whoverse.dev  # no auth — should work
   docker push zot.whoverse.dev/test:latest
   ```

3. **Storage size** — confirm 8Gi is sufficient or adjust `persistence.storage` in `helmrelease.yaml`.

---

## Spec Coverage Check

| Spec section | Task |
|---|---|
| Namespace: storage/ | Task 5 (ks.yaml) |
| Storage: miroir-replicated | Task 2 (helmrelease values) |
| Chart: oci://ghcr.io/project-zot/helm-charts/zot | Task 1 (ocirepository) |
| Mode: readwrite (no auth) | Task 2 (config.json: readOnly:false) |
| Internal only (no external route) | Task 3 (httproute, internal only) |
| Health probes | Task 2 (startupProbe, liveness/readiness hardcoded by chart) |
| HTTPRoute | Task 3 |
| ServiceMonitor | Task 2 (metrics.enabled + serviceMonitor.enabled) |
| storage/kustomization.yaml update | Task 6 |
| Validation + commit | Task 7 |
