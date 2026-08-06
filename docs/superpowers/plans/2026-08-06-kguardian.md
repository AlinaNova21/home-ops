# kguardian Deployment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy kguardian (eBPF traffic/syscall observability → NetworkPolicy/CiliumPolicy/seccomp generation) to a new `security` namespace via GitOps, with internal-only UI exposure and Grafana monitoring.

**Architecture:** A single Helm chart (`oci://ghcr.io/kguardian-dev/charts/kguardian`, tag `1.17.1`) installs controller (privileged DaemonSet, eBPF), broker (Postgres-backed REST API), bundled PostgreSQL 18 (PVC on `miroir-replicated`, no backup — regenerable telemetry), evaluator (audit mode, kept on), and frontend (internal `kguardian.whoverse.dev` only). AI assistant (`llm-bridge`) stays off. Broker emits a ServiceMonitor that vmagent auto-converts; a hand-authored GrafanaDashboard covers the 7 broker gauges.

**Tech Stack:** Flux CD (`OCIRepository` + `HelmRelease` chartRef), Gateway API `HTTPRoute` (internal gateway `internal`/`network`), VictoriaMetrics operator (ServiceMonitor auto-conversion), grafana-operator (`GrafanaFolder`/`GrafanaDashboard`), flate validation.

**Working directory:** `/home/alina/projects/home-ops/.worktrees/feat/kguardian` (worktree already created, `mise` toolchain installed, baseline `just flate-test` green: 186 passed).

**Pre-resolved facts (do not re-derive):**
- OCI chart tag is `1.17.1` (git release tag is `chart/v1.17.1` — the git tag is NOT the OCI tag)
- Chart digest: `sha256:8ac3be61ea8dd9846e57c5f3f393e86ac5bc7e431ded563210b5aa0b066fecf7`
- Chart is NOT cosign-signed → OCIRepository has **no** `verify:` block
- Internal gateway is `name: internal`, `namespace: network` (confirmed by `kubernetes/auth/dex-internal/app/httproute.yaml`)
- Frontend Service renders as `kguardian-frontend`, port `5173` (chart `frontend.service.name`/`frontend.service.port` defaults)
- `security` namespace needs PSA `privileged` (eBPF controller) — mirrors `network`/`auth` ns.yaml shape

---

### Task 1: Create the `security` namespace

**Files:**
- Create: `kubernetes/security/ns.yaml`
- Create: `kubernetes/security/kustomization.yaml`
- Modify: `kubernetes/kustomization.yaml` (append `- security` to resources)

- [ ] **Step 1: Create `kubernetes/security/ns.yaml`**

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: security
  annotations:
    kustomize.toolkit.fluxcd.io/prune: disabled
  labels:
    homelab.whoverse.dev/component: infrastructure
    pod-security.kubernetes.io/enforce: privileged
```

- [ ] **Step 2: Create `kubernetes/security/kustomization.yaml`**

```yaml
---
# yaml-language-server: $schema=https://json.schemastore.org/kustomization
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ns.yaml
```

(No component `ks.yaml` yet — Task 2 adds `kguardian/ks.yaml` and updates this file.)

- [ ] **Step 3: Append `security` to the top-level aggregator `kubernetes/kustomization.yaml`**

Edit `kubernetes/kustomization.yaml` — the resources list currently ends with:

```yaml
  - kopiur-system
  - kro-system
  - reloader
```

Append after `reloader`:

```yaml
  - reloader
  - security
```

- [ ] **Step 4: Validate**

Run: `just flate-test`
Expected: `✓ 186 passed` — unchanged. flate counts Flux Kustomizations, HelmReleases, and source CRs only; the plain `security/` namespace kustomization is not a Flux CR and adds nothing yet (the `security/kguardian` Flux Kustomization arrives in Task 2). No failures. Pre-existing warnings (tailscale-operator, spegel) are unchanged.

- [ ] **Step 5: Commit**

```bash
git add kubernetes/security/ns.yaml kubernetes/security/kustomization.yaml kubernetes/kustomization.yaml
git commit -m "feat(security): add security namespace"
```

---

### Task 2: Add kguardian chart source + Flux Kustomization

**Files:**
- Create: `kubernetes/security/kguardian/ks.yaml`
- Create: `kubernetes/security/kguardian/app/ocirepository.yaml`
- Create: `kubernetes/security/kguardian/app/kustomization.yaml`
- Modify: `kubernetes/security/kustomization.yaml` (add `kguardian/ks.yaml`)

- [ ] **Step 1: Create `kubernetes/security/kguardian/ks.yaml`**

```yaml
---
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/kustomize.toolkit.fluxcd.io/kustomization_v1.json
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: kguardian
  namespace: security
spec:
  interval: 30m
  path: "./kubernetes/security/kguardian/app"
  sourceRef:
    kind: GitRepository
    name: home-ops
    namespace: flux-system
  healthChecks:
    - apiVersion: apps/v1
      kind: DaemonSet
      name: kguardian-controller
      namespace: security
  timeout: 10m
  wait: true
  prune: true
```

- [ ] **Step 2: Create `kubernetes/security/kguardian/app/ocirepository.yaml`**

No `verify:` block — the kguardian chart is not cosign-signed.

```yaml
---
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/source.toolkit.fluxcd.io/ocirepository_v1.json
apiVersion: source.toolkit.fluxcd.io/v1
kind: OCIRepository
metadata:
  name: kguardian
  namespace: security
spec:
  interval: 1h
  layerSelector:
    mediaType: application/vnd.cncf.helm.chart.content.v1.tar+gzip
    operation: copy
  ref:
    tag: "1.17.1"
    digest: sha256:8ac3be61ea8dd9846e57c5f3f393e86ac5bc7e431ded563210b5aa0b066fecf7
  url: oci://ghcr.io/kguardian-dev/charts/kguardian
```

- [ ] **Step 3: Create `kubernetes/security/kguardian/app/kustomization.yaml`**

Only the OCIRepository for now (HelmRelease + HTTPRoute land in Tasks 3–4).

```yaml
---
# yaml-language-server: $schema=https://json.schemastore.org/kustomization
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ocirepository.yaml
```

- [ ] **Step 4: Update `kubernetes/security/kustomization.yaml`**

Change the resources list to:

```yaml
resources:
  - ns.yaml
  - kguardian/ks.yaml
```

- [ ] **Step 5: Validate**

Run: `just flate-test`
Expected: `✓ 188 passed` (186 baseline + the `security/kguardian` Flux Kustomization + the `security/kguardian` OCIRepository). The new Flux Kustomization resolves path `./kubernetes/security/kguardian/app` (exists) and the OCIRepository references the pinned chart (tag + digest).

- [ ] **Step 6: Commit**

```bash
git add kubernetes/security/kguardian kubernetes/security/kustomization.yaml
git commit -m "feat(security): add kguardian chart source"
```

---

### Task 3: Deploy kguardian HelmRelease

**Files:**
- Create: `kubernetes/security/kguardian/app/helmrelease.yaml`
- Modify: `kubernetes/security/kguardian/app/kustomization.yaml` (add `helmrelease.yaml`)

- [ ] **Step 1: Create `kubernetes/security/kguardian/app/helmrelease.yaml`**

```yaml
---
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/helm.toolkit.fluxcd.io/helmrelease_v2.json
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: kguardian
  namespace: security
spec:
  interval: 30m
  chartRef:
    kind: OCIRepository
    name: kguardian
    namespace: security
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
    # Bundled Postgres on miroir-replicated, 10Gi. No kopiur backup:
    # telemetry is regenerable (broker re-learns from runtime behavior).
    database:
      persistence:
        enabled: true
        size: 10Gi
        storageClassName: miroir-replicated
    # Audit-mode evaluator (would-deny/allow verdicts) — keep on.
    evaluator:
      enabled: true
    # AI assistant (llm-bridge) — off; needs an LLM provider key to enable.
    ai:
      enabled: false
    broker:
      metrics:
        serviceMonitor:
          # vmagent (selectAllByDefault) auto-converts plain ServiceMonitors.
          enabled: true
    frontend:
      ingress:
        # Chart ingress unused — HTTPRoute is the ingress (Task 4).
        enabled: false
```

- [ ] **Step 2: Update `kubernetes/security/kguardian/app/kustomization.yaml`**

```yaml
resources:
  - ocirepository.yaml
  - helmrelease.yaml
```

- [ ] **Step 3: Validate**

Run: `just flate-test`
Expected: `✓ 189 passed` (188 + the new HelmRelease). HelmRelease chartRef resolves to the `security/kguardian` OCIRepository.

- [ ] **Step 4: Commit**

```bash
git add kubernetes/security/kguardian/app/helmrelease.yaml kubernetes/security/kguardian/app/kustomization.yaml
git commit -m "feat(security): deploy kguardian"
```

---

### Task 4: Expose kguardian UI internally

**Files:**
- Create: `kubernetes/security/kguardian/app/httproute.yaml`
- Modify: `kubernetes/security/kguardian/app/kustomization.yaml` (add `httproute.yaml`)

- [ ] **Step 1: Create `kubernetes/security/kguardian/app/httproute.yaml`**

Internal gateway only — the broker API is unauthenticated and the frontend calls it from the browser, so the UI must NOT be on the public Cloudflare gateway.

```yaml
---
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/gateway.networking.k8s.io/httproute_v1.json
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: kguardian
  namespace: security
spec:
  parentRefs:
    - name: internal
      namespace: network
  hostnames:
    - kguardian.whoverse.dev
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: kguardian-frontend
          port: 5173
```

- [ ] **Step 2: Update `kubernetes/security/kguardian/app/kustomization.yaml`**

```yaml
resources:
  - ocirepository.yaml
  - helmrelease.yaml
  - httproute.yaml
```

- [ ] **Step 3: Validate**

Run: `just flate-test`
Expected: `✓ 189 passed` — unchanged. HTTPRoute is a plain Gateway API resource inside the app kustomization, not a Flux CR; flate does not count it (it validates the app kustomization renders).

- [ ] **Step 4: Commit**

```bash
git add kubernetes/security/kguardian/app/httproute.yaml kubernetes/security/kguardian/app/kustomization.yaml
git commit -m "feat(security): expose kguardian on internal gateway"
```

---

### Task 5: Add Grafana folder + kguardian dashboard

**Files:**
- Modify: `kubernetes/monitoring/grafana/app/folders.yaml` (append `security` folder)
- Create: `kubernetes/monitoring/grafana/app/dashboards/kguardian.yaml`
- Modify: `kubernetes/monitoring/grafana/app/kustomization.yaml` (add `dashboards/kguardian.yaml`)

- [ ] **Step 1: Append the `security` GrafanaFolder to `kubernetes/monitoring/grafana/app/folders.yaml`**

The file currently ends with the `ceph` folder block. Append:

```yaml
---
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaFolder
metadata:
  name: security
  namespace: monitoring
spec:
  instanceSelector:
    matchLabels:
      dashboards: "grafana"
  title: Security
```

- [ ] **Step 2: Create `kubernetes/monitoring/grafana/app/dashboards/kguardian.yaml`**

Hand-authored (no official kguardian dashboard exists upstream). Covers all 7 broker gauges.

```yaml
---
# kguardian broker dashboard — hand-authored (no upstream dashboard exists)
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDashboard
metadata:
  name: kguardian
  namespace: monitoring
spec:
  folderRef: security
  instanceSelector:
    matchLabels:
      dashboards: "grafana"
  datasources:
    - inputName: DS_PROMETHEUS
      datasourceName: VictoriaMetrics
  json: |
    {"__inputs":[{"name":"DS_PROMETHEUS","label":"prometheus","description":"","type":"datasource","pluginId":"prometheus","pluginName":"Prometheus"}],"annotations":{"list":[{"builtIn":1,"datasource":{"type":"grafana","uid":"-- Grafana --"},"enable":true,"hide":true,"iconColor":"rgba(0, 211, 255, 1)","name":"Annotations & Alerts","type":"dashboard"}]},"editable":true,"graphTooltip":1,"panels":[{"collapsed":false,"gridPos":{"h":1,"w":24,"x":0,"y":0},"id":1,"panels":[],"title":"Broker health","type":"row"},{"datasource":{"type":"prometheus","uid":"${DS_PROMETHEUS}"},"fieldConfig":{"defaults":{"color":{"mode":"thresholds"},"mappings":[{"options":{"0":{"color":"red","text":"DOWN"},"1":{"color":"green","text":"UP"}},"type":"value"}],"thresholds":{"mode":"absolute","steps":[{"color":"red","value":null},{"color":"red","value":0},{"color":"green","value":1}]},"unit":"none"},"overrides":[]},"gridPos":{"h":6,"w":8,"x":0,"y":1},"id":2,"options":{"colorMode":"value","graphMode":"area","justifyMode":"auto","orientation":"auto","reduceOptions":{"calcs":["lastNotNull"],"fields":"","values":false},"textMode":"auto"},"targets":[{"datasource":{"type":"prometheus","uid":"${DS_PROMETHEUS}"},"expr":"broker_db_reachable","legendFormat":"DB reachable","refId":"A"}],"title":"broker_db_reachable","type":"stat"},{"datasource":{"type":"prometheus","uid":"${DS_PROMETHEUS}"},"fieldConfig":{"defaults":{"color":{"mode":"thresholds"},"mappings":[{"options":{"0":{"color":"red","text":"NOT READY"},"1":{"color":"green","text":"READY"}},"type":"value"}],"thresholds":{"mode":"absolute","steps":[{"color":"red","value":null},{"color":"red","value":0},{"color":"green","value":1}]},"unit":"none"},"overrides":[]},"gridPos":{"h":6,"w":8,"x":8,"y":1},"id":3,"options":{"colorMode":"value","graphMode":"area","justifyMode":"auto","orientation":"auto","reduceOptions":{"calcs":["lastNotNull"],"fields":"","values":false},"textMode":"auto"},"targets":[{"datasource":{"type":"prometheus","uid":"${DS_PROMETHEUS}"},"expr":"broker_db_schema_ready","legendFormat":"Schema ready","refId":"A"}],"title":"broker_db_schema_ready","type":"stat"},{"datasource":{"type":"prometheus","uid":"${DS_PROMETHEUS}"},"fieldConfig":{"defaults":{"color":{"mode":"thresholds"},"mappings":[{"options":{"0":{"color":"red","text":"DISABLED"},"1":{"color":"green","text":"ENABLED"}},"type":"value"}],"thresholds":{"mode":"absolute","steps":[{"color":"red","value":null},{"color":"red","value":0},{"color":"green","value":1}]},"unit":"none"},"overrides":[]},"gridPos":{"h":6,"w":8,"x":16,"y":1},"id":4,"options":{"colorMode":"value","graphMode":"area","justifyMode":"auto","orientation":"auto","reduceOptions":{"calcs":["lastNotNull"],"fields":"","values":false},"textMode":"auto"},"targets":[{"datasource":{"type":"prometheus","uid":"${DS_PROMETHEUS}"},"expr":"broker_audit_enabled","legendFormat":"Audit enabled","refId":"A"}],"title":"broker_audit_enabled","type":"stat"},{"datasource":{"type":"prometheus","uid":"${DS_PROMETHEUS}"},"fieldConfig":{"defaults":{"color":{"mode":"thresholds"},"mappings":[],"thresholds":{"mode":"absolute","steps":[{"color":"green","value":null},{"color":"red","value":0}]},"unit":"s"},"overrides":[]},"gridPos":{"h":6,"w":8,"x":0,"y":7},"id":5,"options":{"colorMode":"value","graphMode":"none","justifyMode":"auto","orientation":"auto","reduceOptions":{"calcs":["lastNotNull"],"fields":"","values":false},"textMode":"auto"},"targets":[{"datasource":{"type":"prometheus","uid":"${DS_PROMETHEUS}"},"expr":"broker_uptime_seconds","legendFormat":"Uptime","refId":"A"}],"title":"broker_uptime_seconds","type":"stat"},{"collapsed":false,"gridPos":{"h":1,"w":24,"x":0,"y":13},"id":6,"panels":[],"title":"Broker capacity","type":"row"},{"datasource":{"type":"prometheus","uid":"${DS_PROMETHEUS}"},"fieldConfig":{"defaults":{"color":{"mode":"palette-classic"},"custom":{"drawStyle":"line","fillOpacity":10,"lineWidth":1,"showPoints":"never"},"unit":"short"},"overrides":[]},"gridPos":{"h":6,"w":8,"x":0,"y":14},"id":7,"options":{"legend":{"calcs":["lastNotNull"],"displayMode":"list","placement":"bottom","showLegend":true},"tooltip":{"mode":"multi","sort":"none"}},"targets":[{"datasource":{"type":"prometheus","uid":"${DS_PROMETHEUS}"},"expr":"broker_audit_inflight_available","legendFormat":"inflight available","refId":"A"}],"title":"broker_audit_inflight_available","type":"timeseries"},{"datasource":{"type":"prometheus","uid":"${DS_PROMETHEUS}"},"fieldConfig":{"defaults":{"color":{"mode":"palette-classic"},"custom":{"drawStyle":"line","fillOpacity":10,"lineWidth":1,"showPoints":"never"},"unit":"short"},"overrides":[]},"gridPos":{"h":6,"w":8,"x":8,"y":14},"id":8,"options":{"legend":{"calcs":["lastNotNull"],"displayMode":"list","placement":"bottom","showLegend":true},"tooltip":{"mode":"multi","sort":"none"}},"targets":[{"datasource":{"type":"prometheus","uid":"${DS_PROMETHEUS}"},"expr":"broker_db_pool_idle","legendFormat":"pool idle","refId":"A"}],"title":"broker_db_pool_idle","type":"timeseries"},{"datasource":{"type":"prometheus","uid":"${DS_PROMETHEUS}"},"fieldConfig":{"defaults":{"color":{"mode":"palette-classic"},"custom":{"drawStyle":"line","fillOpacity":10,"lineWidth":1,"showPoints":"never"},"unit":"short"},"overrides":[]},"gridPos":{"h":6,"w":8,"x":16,"y":14},"id":9,"options":{"legend":{"calcs":["lastNotNull"],"displayMode":"list","placement":"bottom","showLegend":true},"tooltip":{"mode":"multi","sort":"none"}},"targets":[{"datasource":{"type":"prometheus","uid":"${DS_PROMETHEUS}"},"expr":"broker_db_pool_max","legendFormat":"pool max","refId":"A"}],"title":"broker_db_pool_max","type":"timeseries"}],"refresh":"30s","schemaVersion":39,"tags":["kguardian"],"templating":{"list":[{"current":{},"hide":0,"label":"Prometheus","name":"DS_PROMETHEUS","options":[],"query":"prometheus","refresh":1,"regex":"","skipUrlSync":false,"type":"datasource"}]},"time":{"from":"now-6h","to":"now"},"timepicker":{},"timezone":"","title":"kguardian","uid":"kguardian"}
```

- [ ] **Step 3: Register the dashboard in `kubernetes/monitoring/grafana/app/kustomization.yaml`**

Append to the resources list:

```yaml
  - dashboards/kguardian.yaml
```

- [ ] **Step 4: Validate**

Run: `just flate-test`
Expected: `✓ 189 passed` — unchanged. GrafanaFolder/GrafanaDashboard are grafana-operator CRs, not Flux CRs; flate validates the grafana kustomization renders them. (The embedded dashboard JSON is validated as a string; Grafana migrates schema versions on load.)

- [ ] **Step 5: Commit**

```bash
git add kubernetes/monitoring/grafana/app/folders.yaml kubernetes/monitoring/grafana/app/dashboards/kguardian.yaml kubernetes/monitoring/grafana/app/kustomization.yaml
git commit -m "feat(monitoring): add kguardian dashboard"
```

---

### Task 6: Full validation + push + PR

- [ ] **Step 1: Run the full validation gate**

```bash
just hooks-install
pre-commit run --all-files
just flate-test
```

Expected: gitleaks + trufflehog **Passed**; flate `✓ 189 passed` (no failures; the 2 pre-existing warnings unchanged). If the repo's structure pre-commit hook complains about `kubernetes/security/`, fix and re-run — the `ks.yaml` `metadata.namespace: security` must match the `kubernetes/security/` directory and the namespace `kustomization.yaml` must list `ns.yaml` first (both already true).

- [ ] **Step 2: Verify the working tree contents**

Run: `git status --short`
Expected: no untracked/modified files beyond the 10 created/updated manifests.

- [ ] **Step 3: Push**

```bash
git push origin feat/kguardian
```

- [ ] **Step 4: Create PR**

```bash
gh pr create --fill
```

Expected: PR `feat/kguardian` with the 6 commits; CI runs kustomize build + kubeconform on the changed paths.

- [ ] **Step 5: Post-merge (manual, workstation, not part of the PR)**

After the PR merges and Flux reconciles:
1. `kubectl get pods -n security` → controller (per node), broker, db, evaluator, frontend all `Running`.
2. `kubectl port-forward -n security svc/kguardian-broker 9090:9090` + `curl localhost:9090/health` → `Healthy!`.
3. Install the CLI: `kubectl kguardian` via `advisor/v1.6.1` release assets, then let workloads run 5–15 min before generating policies (`kubectl kguardian gen networkpolicy <pod> -n <ns>` — dry-run default).
