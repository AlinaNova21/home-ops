# Prep the cluster for kro (no ResourceGraphDefinitions yet)

- **Date:** 2026-07-25
- **Status:** Draft, pending user review
- **Owner:** home-ops maintainers

## 1. Problem

[kro](https://kro.run) (Kube Resource Orchestrator, Kubernetes SIG
Cloud Provider subproject) lets us define composite Kubernetes APIs as
`ResourceGraphDefinition` (RGD) resources and have a controller create
and reconcile the underlying resource set. Before any RGDs can be
authored, the cluster needs:

1. A namespace for the controller pod, owned by Flux like every other
   system namespace in this repo.
2. A `HelmRepository` declaration for the OCI chart at
   `oci://registry.k8s.io/kro/charts`.
3. A pinned `HelmRelease` installing the chart with:
   - RBAC in **aggregation** mode (kro's recommended setting — narrower
     than `unrestricted`, which is the chart default).
   - Metrics endpoint exposed and scraped by the in-cluster monitoring
     stack.
4. No `ResourceGraphDefinition` instances yet (per the explicit ask
   "no definitions yet, just prep").

The [kro install docs](https://kro.run/docs/getting-started/Installation)
explicitly call out that **the chart installs CRDs but `helm upgrade`
does not replace them** — release notes must be checked per version and
`kubectl apply` applied manually if a kro release changes CRD shapes.
That constraint shapes the prep (we accept it; no automation added in
this round).

## 2. Approach

Mirror the existing `node-feature-discovery` / `kopiur` / `external-secrets`
shape for a system controller:

- One namespace: `kro-system` (matches kro's own default, matches the
  repo's `*-system` convention).
- One component: `kro` under the namespace.
- One OCI `HelmRepository` (`kro`) in `flux-config/registry/helm/`,
  pointing at `oci://registry.k8s.io/kro/charts` with the same
  `interval: 24h` shape as `nfd.yaml`.
- One `HelmRelease` (pinned `version: 0.9.2`, latest as of 2026-07-25)
  overriding `rbac.mode=aggregation`, `metrics.service.create=true`,
  `metrics.serviceMonitor.enabled=true`.
- Flux `Kustomization/kro` with `wait: true`, `prune: false`, a
  `healthCheck` on the deployment — same shape as the node-feature-discovery
  Kustomization.

`just deploy` / `flux reconcile` cadence picks up the new manifests
unchanged; no Justfile or bootstrap changes needed.

## 3. Target layout

```text
kubernetes/
├── kustomization.yaml                 (EDIT — add `- kro-system`)
├── flux-config/
│   └── registry/
│       └── helm/
│           ├── kustomization.yaml     (EDIT — add `- kro.yaml`)
│           └── kro.yaml               (NEW — HelmRepository/kro, OCI)
└── kro-system/                        (NEW namespace)
    ├── ns.yaml                        (NEW — Namespace/kro-system, prune:disabled)
    ├── kustomization.yaml             (NEW — ns.yaml + kro/ks.yaml)
    └── kro/
        ├── ks.yaml                    (NEW — Kustomization/kro)
        └── app/
            ├── kustomization.yaml     (NEW — helmrelease.yaml)
            └── helmrelease.yaml       (NEW — HelmRelease/kro @ 0.9.2)
```

No files are deleted in this change.

## 4. New resources

### 4.1 `Namespace/kro-system`

```yaml
# kubernetes/kro-system/ns.yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: kro-system
  annotations:
    kustomize.toolkit.fluxcd.io/prune: disabled
```

Matches the `prune: disabled` pattern used by every other `*-system`
namespace in this repo (kopiur-system, inteldeviceplugins-system,
cert-manager, etc.).

### 4.2 `HelmRepository/kro`

```yaml
# kubernetes/flux-config/registry/helm/kro.yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: kro
  namespace: flux-system
spec:
  type: oci
  url: oci://registry.k8s.io/kro/charts
  interval: 24h
```

Mirrors `kubernetes/flux-config/registry/helm/nfd.yaml` exactly,
swapping the chart path. Referenced from
`kubernetes/flux-config/registry/helm/kustomization.yaml`.

### 4.3 `Kustomization/kro`

```yaml
# kubernetes/kro-system/kro/ks.yaml
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: kro
  namespace: kro-system
spec:
  interval: 30m
  path: "./kro-system/kro/app"
  sourceRef:
    kind: OCIRepository
    name: home-ops
    namespace: flux-system
  healthChecks:
    - apiVersion: apps/v1
      kind: Deployment
      name: kro
      namespace: kro-system
  timeout: 10m
  wait: true
  prune: false
```

No `dependsOn` — kro has no upstream system prerequisite (only the
`OCIRepository/home-ops` source, which is already depended on by every
other Kustomization in this tree).

### 4.4 `HelmRelease/kro`

```yaml
# kubernetes/kro-system/kro/app/helmrelease.yaml
---
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: kro
  namespace: kro-system
spec:
  interval: 30m
  chart:
    spec:
      chart: kro
      version: 0.9.2                 # Renovate bumps (flux manager + home-ops pattern)
      sourceRef:
        kind: HelmRepository
        name: kro
        namespace: flux-system
      interval: 24h
  install:
    createNamespace: false           # Flux owns the namespace via ns.yaml
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
    rbac:
      mode: aggregation               # kro-recommended; per-RGD ClusterRoles extend later
    config:
      enableLeaderElection: true
      logLevel: info
    metrics:
      service:
        create: true                 # expose :8078
        type: ClusterIP
        port: 8078
      serviceMonitor:
        enabled: true                # VictoriaMetrics picks it up
```

`version: 0.9.2` — the Renovate `flux` manager in
`.github/renovate.json` (lines 7–11) picks up `version:` fields under
`kubernetes/.+\.ya?ml` automatically. The "All other Helm charts:
auto-merge minor, patch, and digest" rule (lines 86–97) makes Renovate
push minor/patch bumps directly. Major bumps open a PR with the
`update/major` label (lines 137–143).

### 4.5 `kustomization.yaml` files

`kubernetes/kro-system/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ns.yaml
  - kro/ks.yaml
```

`kubernetes/kro-system/kro/app/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - helmrelease.yaml
```

### 4.6 Top-level edits (two lists, one line each)

`kubernetes/kustomization.yaml` — add `- kro-system` to the resources
list (current list ends at `- kopiur-system`).

`kubernetes/flux-config/registry/helm/kustomization.yaml` — add
`- kro.yaml` to the resources list (current list ends at `- error-pages.yaml`).

## 5. What ships on first reconcile

After the next OCI build of `kubernetes/`:
- `Namespace/kro-system` (via `ns.yaml`).
- `HelmRelease/kro` in `kro-system` reconciled by Flux to the chart's
  resources:
  - `Deployment/kro` (1 replica, leader-elected, securityContext
    `runAsUser: 1000`).
  - `ServiceAccount/kro`, `ClusterRole/kro-controller` (aggregation
    mode — chart's base role plus an aggregation rule matching
    `rbac.kro.run/aggregate-to-controller: "true"`),
    `ClusterRoleBinding/kro`.
  - `CRD/kro.run_resourcegraphdefinitions`,
    `CRD/internal.kro.run_graphrevisions`.
  - `Service/kro-controller-metrics-service`,
    `ServiceMonitor/kro` (because `metrics.service.create` and
    `metrics.serviceMonitor.enabled` are both `true`).

## 6. What this prep deliberately does NOT do

- No `ResourceGraphDefinition` files. Per the user's "no definitions
  yet, just prep" ask.
- No aggregate `ClusterRole` resources beyond the chart's base. The
  aggregation mode means every future RGD is responsible for shipping a
  labelled `ClusterRole` granting access to the resources it touches;
  that discipline is a per-RGD concern and lives in follow-up commits.
- No `deploy-infrastructure.sh` or Justfile changes. `just deploy`
  ("build OCI + reconcile cluster") already covers the next push, and
  the per-recipe workflows don't need updates for a new
  install-only component.
- No CRD-update automation. Operator must read kro release notes and
  manually `kubectl apply` the chart's CRD YAML when a kro upgrade
  changes `ResourceGraphDefinition` shape. This is kro's documented
  upgrade behaviour and is acknowledged rather than worked around.
- No webhook receiver / notifications / external integration. kro
  ships only its core controller.

## 7. Risks and known limitations

1. **Chart CRDs are not auto-upgraded.** First install is fine. When
   future kro releases change `ResourceGraphDefinition` or
   `GraphRevision` CRD shape, the operator must apply the new CRDs
   before `helm upgrade` (otherwise the controller fails to start
   against the newer CRD shape). Action when that happens:
   `kubectl apply -f https://github.com/kubernetes-sigs/kro/releases/download/v<new>/kro-core-install-manifests.yaml` (only the CRDs from that manifest). This will be revisited in a follow-up if it becomes routine.
2. **`wait: true` + single replica + leader election** can produce a
   slow first reconcile if the OCI artifact hasn't been pushed yet for
   this path. Workaround if it stalls: `kubectl annotate kustomization
   kro -n kro-system fluxcd.io/refresh="$(date -Iseconds)" --overwrite`.
3. **Aggregation mode means per-RGD ClusterRoles** are mandatory for
   every future RGD that touches real resources. Intentional — keeps
   blast radius small — but each new RGD definition carries that
   extra resource. The first RGD design should make this concrete.
4. **`metrics.service.create=true` requires CiliumNetworkPolicy
   allow-list** to actually be scraped. The cluster's monitoring
   pipeline already scrapes in-cluster `ServiceMonitor`s, so this
   should "just work"; if scrape fails post-deploy, check the
   VictoriaMetrics `PodMonitor`/`ServiceMonitor` selectors.
5. **Renovate regex rule does not trigger on `version:` lines without
   the `# renovate: datasource=...` comment.** The `version:` field in
   `HelmRelease/kro` is picked up by the built-in Renovate `flux`
   manager (which matches the YAML structure, not the comment), so
   this is fine. Confirmed against `.github/renovate.json` lines 7–11
   and the existing `kubernetes/kube-system/node-feature-discovery/app/helmrelease.yaml`
   which uses the same shape without a `# renovate:` comment.

## 8. Validation

Local equivalents of the CI checks in
`.github/workflows/validate-kubernetes.yml`:

```bash
for dir in kubernetes/flux-config kubernetes; do
  echo "=== $dir ==="
  kustomize build "$dir" | kubeconform -strict -ignore-missing-schemas \
    -schema-location default \
    -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
done
```

Pre-commit hook also enforces the namespace/component structure rules
in `AGENTS.md` (must have `ns.yaml`, must reference it first, component
`ks.yaml` `metadata.namespace` must match the parent directory).

Cluster side, after OCI build:

```bash
flux reconcile source oci home-ops -n flux-system
flux reconcile kustomization cluster -n flux-system
flux get helmreleases -A | grep kro
kubectl -n kro-system get pods,services,svcmonitor,clusterrole,clusterrolebinding
kubectl get crd resourcegraphdefinitions.kro.run graphrevisions.internal.kro.run
kubectl -n kro-system wait --for=condition=ready pod -l app.kubernetes.io/name=kro --timeout=5m
```

Smoke test (no RGDs expected yet):

```bash
kubectl api-resources | grep kro.run    # resourcegraphdefinitions should appear
```

## 9. Rollback

```bash
git revert <commit-sha>          # removes all files and edits in §4.6
flux reconcile kustomization cluster -n flux-system
```

Or manually: `kubectl delete -f kubernetes/kro-system/` — the
`prune: disabled` namespace annotation means a manual
`kubectl delete namespace kro-system` is required to fully clean up if
desired.
