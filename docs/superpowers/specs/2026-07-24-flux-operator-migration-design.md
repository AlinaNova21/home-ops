# Migrate Flux installation from HelmRelease to Flux Operator

- **Date:** 2026-07-24
- **Status:** Draft, pending user review
- **Owner:** home-ops maintainers

## 1. Problem

Flux CD is currently installed and managed by a self-applied
`HelmRelease/flux2` in `kubernetes/flux-config/`. The cluster has three
bootstrap paths with version drift (`kubernetes/bootstrap/helmfile.yaml`
pins flux 2.18.4, `Justfile` pins flux 2.16.2, the GitOps `HelmRelease`
pins flux 2.19.0). Upgrades, configuration changes, and health checks all
flow through imperative Helm values rather than through a Kubernetes-native
API.

The [Flux Operator](https://github.com/controlplaneio-fluxcd/flux-operator)
provides a `FluxInstance` CR that owns the lifecycle of the Flux
controllers (kustomize, helm, source, notification, image-reflector,
image-automation) including upgrades, health, and configuration. Replacing
the self-managed `HelmRelease/flux2` with `FluxInstance` gives us:

1. A single source of truth for the Flux version (in `FluxInstance.spec.distribution.version`).
2. A typed, reconcilable configuration surface instead of Helm values.
3. A migration path toward operator-managed workflows (`FluxReport`,
   `FluxAlert`, etc.) without re-installing Flux.
4. Removal of one of the three bootstrap paths (the imperative
   `HelmRelease/flux2`) — flux-operator takes its place.

The goal of this design is to migrate from `HelmRelease/flux2` to
`FluxInstance` in a single cutover, install `flux-operator` via the
existing `kubernetes/bootstrap/helmfile.yaml`, and preserve the current
controller behavior (`--concurrent=16`, `--requeue-dependency=5s`,
image-reflector + image-automation controllers enabled, `installCRDs: true`).

## 2. Approach

Install `flux-operator` via helmfile as the first Flux-related release
(after Cilium). Let GitOps reconcile the operator's inputs (`FluxInstance`)
into `flux-system`. Replace the existing `HelmRelease/flux2` with a
`FluxInstance` custom resource. Remove the two non-canonical bootstrap
paths (`kubernetes/bootstrap.sh` and the Justfile `bootstrap-flux` recipe)
in favor of helmfile as the single source of truth.

Rationale for keeping the operator in `flux-system`:

- The repo convention is one namespace per concern; `flux-system` already
  exists and is the natural home for Flux's lifecycle.
- The existing webhook receiver lives at `kubernetes/flux-system/` and
  depends on `external-secrets-config`; adding the operator there reuses
  the same kustomization aggregator entry.
- Co-location avoids a new namespace, a new `ks.yaml`, and a new entry in
  `kubernetes/kustomization.yaml`.

Rationale for **single cutover** over staged migration:

- The user explicitly chose single cutover.
- `flux-operator` and `FluxInstance` are designed for a clean swap — once
  the operator is installed, applying `FluxInstance` immediately brings the
  controllers up at the requested version, and the operator reconciles
  them continuously.
- A staged approach leaves the operator and the old `HelmRelease/flux2`
  coexisting, which is operationally confusing and produces two
  authoritative sources of truth for the Flux version.

## 3. Target layout

```text
kubernetes/
├── flux-config/
│   ├── namespace.yaml                    (existing)
│   ├── registries.yaml                   (existing)
│   ├── flux-system.yaml                  (EDIT — healthcheck target)
│   ├── cluster.yaml                      (existing — depends on flux-system)
│   ├── kustomization.yaml                (EDIT — drop flux-helmrelease.yaml)
│   └── registry/
│       └── helm/
│           ├── fluxcd-community.yaml     (existing — kept)
│           ├── controlplaneio.yaml       (NEW — oci://ghcr.io/controlplaneio-fluxcd/charts)
│           └── kustomization.yaml        (EDIT — add controlplaneio.yaml)
├── flux-system/                          (existing namespace, contains webhook receiver)
│   ├── ns.yaml                           (existing)
│   ├── kustomization.yaml                (EDIT — add flux-operator + flux-instance)
│   ├── flux-operator/
│   │   ├── ks.yaml                       (NEW)
│   │   └── app/
│   │       └── helmrelease.yaml          (NEW — Flux HelmRelease for operator chart)
│   └── flux-instance/
│       ├── ks.yaml                       (NEW)
│       └── app/
│           └── fluxinstance.yaml         (NEW)
└── bootstrap/
    └── helmfile.yaml                     (EDIT — add operator release, remove flux2)
```

Removed files:

- `kubernetes/flux-config/flux-helmrelease.yaml` — replaced by
  `FluxInstance`.
- `kubernetes/bootstrap.sh` — replaced by helmfile.
- `Justfile` `bootstrap-flux` recipe — replaced by helmfile.

## 4. New resources

### 4.1 `HelmRepository/controlplaneio`

```yaml
# kubernetes/flux-config/registry/helm/controlplaneio.yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: controlplaneio
  namespace: flux-system
spec:
  type: oci
  interval: 24h
  url: oci://ghcr.io/controlplaneio-fluxcd/charts
  provider: generic
```

Referenced from `kubernetes/flux-config/registry/helm/kustomization.yaml`.

### 4.2 `HelmRelease/flux-operator`

```yaml
# kubernetes/flux-system/flux-operator/app/helmrelease.yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: flux-operator
  namespace: flux-system
spec:
  interval: 24h
  chart:
    spec:
      chart: flux-operator
      version: "<pinned-at-impl-time>"
      sourceRef:
        kind: HelmRepository
        name: controlplaneio
        namespace: flux-system
  # flux-system namespace already exists (created by bootstrap)
  values:
    # TBD at impl time — see Section 7 for what values must be set.
```

### 4.3 `FluxInstance/flux`

```yaml
# kubernetes/flux-system/flux-instance/app/fluxinstance.yaml
apiVersion: fluxcd.controlplane.io/v1
kind: FluxInstance
metadata:
  name: flux                       # REQUIRED: must be 'flux' (CRD x-kubernetes-validations)
  namespace: flux-system
spec:
  distribution:
    # renovate: datasource=github-releases depName=controlplaneio-fluxcd/distribution
    version: "2.9.4"               # pinned; renovate bumps per Section 7
    registry: "ghcr.io/fluxcd"
    # imagePullSecret omitted — Flux images are public
  components:
    - source-controller            # matches current HelmRelease (no source-watcher)
    - kustomize-controller
    - helm-controller
    - notification-controller
    - image-reflector-controller
    - image-automation-controller
  cluster:
    size: medium                   # default; tune at impl time
  kustomize:
    patches:
      # Preserve --concurrent=16, --requeue-dependency=5s on kustomize + helm;
      # --requeue-dependency=5s on source (currently in flux-helmrelease.yaml L44–56).
      - target:
          kind: Deployment
          labelSelector: "app.kubernetes.io/name in (kustomize-controller, helm-controller)"
        patch: |
          - op: add
            path: /spec/template/spec/containers/0/args/-
            value: --concurrent=16
          - op: add
            path: /spec/template/spec/containers/0/args/-
            value: --requeue-dependency=5s
      - target:
          kind: Deployment
          labelSelector: "app.kubernetes.io/name=source-controller"
        patch: |
          - op: add
            path: /spec/template/spec/containers/0/args/-
            value: --requeue-dependency=5s
```

This preserves every controller flag currently set in
`kubernetes/flux-config/flux-helmrelease.yaml` lines 44–56, plus the
image reflector + image automation controllers enabled by
`bootstrap.sh` lines 64–69. Note: `FluxInstance` does not have a
`spec.helm.args` or `spec.source.args` field — controller arguments are
applied via JSON patches targeting the controller Deployments.

The CRD enforces `metadata.name == 'flux'` via
`x-kubernetes-validations` — any other name will be rejected by the API
server.

### 4.4 `Kustomization/flux-operator` and `Kustomization/flux-instance`

Both live in `flux-system/` namespace, follow the standard `ks.yaml`
shape (`metadata.namespace` matching the parent directory):

```yaml
# kubernetes/flux-system/flux-operator/ks.yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: flux-operator
  namespace: flux-system
spec:
  interval: 24h
  path: "./flux-system/flux-operator/app"
  prune: false
  sourceRef:
    kind: OCIRepository
    name: home-ops
```

The `flux-instance` ks.yaml is identical with `name: flux-instance` and
`path: "./flux-system/flux-instance/app"`. Both are added to
`kubernetes/flux-system/kustomization.yaml`.

## 5. Bootstrap choreography (`kubernetes/bootstrap/helmfile.yaml`)

```yaml
repositories:
  - name: cilium
    url: https://helm.cilium.io
  - name: controlplaneio
    url: ghcr.io/controlplaneio-fluxcd/charts
    oci: true

releases:
  - name: cilium
    namespace: kube-system
    chart: cilium/cilium
    version: 1.19.6
    # (existing values)

  - name: flux-operator
    namespace: flux-system
    chart: controlplaneio/flux-operator
    version: "<pinned-at-impl-time>"
    createNamespace: false
    values:
      # TBD at impl time
```

The `flux2` release is removed. Once helmfile exits, the root Flux
`Kustomization/cluster` reconciles `./`, picks up
`flux-system/flux-operator/` and `flux-system/flux-instance/`, the
operator reconciles `FluxInstance`, and the Flux controllers come online.

## 6. Removed resources

- `kubernetes/flux-config/flux-helmrelease.yaml` — deleted.
- `kubernetes/flux-config/kustomization.yaml` — drop the
  `flux-helmrelease.yaml` reference.
- `kubernetes/flux-config/flux-system.yaml` — `healthCheck` changes from
  `kind: HelmRelease, name: flux2` to `kind: FluxInstance, name: flux`
  (operator API: `fluxcd.controlplane.io/v1`).
- `kubernetes/bootstrap.sh` — deleted (delegated to helmfile).
- `Justfile` — `bootstrap-flux` and `bootstrap-helmfile` recipes
  consolidated into one `bootstrap-helmfile` that calls helmfile
  directly; `bootstrap-flux` and `flux-configure` removed.
- `Justfile` `flux-bootstrap` (if any) — removed.

## 7. Open items resolved at implementation time

1. **`flux-operator` chart version.** Pin to the latest stable release
   available at implementation time. As of 2026-07-24, the latest chart
   version is `0.27.0` (`oci://ghcr.io/controlplaneio-fluxcd/charts/flux-operator:0.27.0`).
   The repo's convention is pinned chart versions (see
   `kubernetes/flux-config/flux-helmrelease.yaml` line 11: `version: 2.19.0`).
   Renovate handles bumps.
2. **`FluxInstance.spec.distribution.version`.** Pin to `"2.9.3"` (exact).
   The current cluster runs Flux 2.9.1 (chart 2.19.0; appVersion
   confirmed via `oci://ghcr.io/fluxcd-community/charts/flux2`
   metadata). The latest Flux release is `v2.9.3` (per
   `github.com/controlplaneio-fluxcd/distribution` tags, fetched
   2026-07-24). Using a concrete pin produces a zero-change cutover.
   **Renovate guidance**: the field is a plain string under
   `FluxInstance.spec.distribution.version` (not a HelmRelease), so the
   built-in `flux` manager in `.github/renovate.json` does not pick it
   up. Mark it for the existing `customManagers.regex` rule (lines
   17-28) by prefixing the version with the convention comment:
   `# renovate: datasource=github-releases depName=controlplaneio-fluxcd/distribution`
   on the line directly above `version:`. Renovate will then propose
   bumps; the global `matchUpdateTypes: [patch]` rule (lines 30-37)
   auto-merges patch updates silently.
3. **`distribution.imagePullSecret`.** Omitted — Flux images are pulled
   from the public `ghcr.io/fluxcd` registry, no secret required.
4. **Operator Helm values.** Default chart values are sufficient.
   Notable defaults preserved: `installCRDs: true`, `priorityClassName: ""`
   (operator will not set cluster-critical by default), `rbac.create: true`
   (required for FluxInstance reconciliation).
5. **`flux-local` validation job.** `.github/workflows/validate-kubernetes.yml`
   line 79 disables `flux-local test`. Re-enable it so the operator CRDs
   and `FluxInstance` types are validated end-to-end before merge.
6. **Cluster size tuning.** `FluxInstance.spec.cluster.size` defaults
   to `medium`. The cluster has 5 nodes (3 control-plane, 2 workers per
   `kubectl get nodes`). `medium` is appropriate; revisit if controller
   resource pressure is observed.

## 8. Validation

- `kustomize build kubernetes/flux-config | kubeconform -strict -ignore-missing-schemas -schema-location default -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'`
- `kustomize build kubernetes | kubeconform …`
- `pre-commit run --all-files` — enforces the namespace/component
  structure rules in `AGENTS.md`.
- Manual bootstrap test on a fresh cluster (or documented in the
  implementation plan): helmfile install → operator healthy →
  `FluxInstance` reconciled → `kubectl get pods -n flux-system` shows
  all Flux controllers running at the requested version.
- Post-cutover smoke test: `flux check` reports the same controllers
  and flags as before the migration.

## 9. Rollback

If `FluxInstance` fails to reconcile:

1. `kubectl delete fluxinstance flux -n flux-system` — operator
   uninstalls the controllers it manages.
2. `kubectl apply -f kubernetes/flux-config/flux-helmrelease.yaml` —
   restores `HelmRelease/flux2` from git (the file is in git history).

Bootstrap rollback: revert `bootstrap/helmfile.yaml` and re-run helmfile.
