# Migrate Flux installation from HelmRelease to Flux Operator Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `HelmRelease/flux2` with a Flux Operator–managed `FluxInstance` so that Flux's controller lifecycle is owned by `flux-operator` instead of by a self-applied HelmRelease.

**Architecture:** Install `flux-operator` via `kubernetes/bootstrap/helmfile.yaml` (the canonical bootstrap path) as the first Flux-related release after Cilium. Move the operator into `kubernetes/flux-system/flux-operator/` (HelmRelease sourced from the new `HelmRepository/controlplaneio`). Define a `FluxInstance` at `kubernetes/flux-system/flux-instance/app/fluxinstance.yaml` that mirrors the current `HelmRelease/flux2` controller set and flags (via JSON patches). Remove `kubernetes/flux-config/flux-helmrelease.yaml`, `kubernetes/bootstrap.sh`, and the Justfile `bootstrap-flux` / `flux-configure` recipes. Re-enable the `flux-local` CI job so `FluxInstance` types are validated end-to-end.

**Tech Stack:** Flux CD v2.19, Flux Operator v0.27.0, Kustomize, Helmfile, OCI charts (`oci://ghcr.io/controlplaneio-fluxcd/charts`).

**Spec:** `docs/superpowers/specs/2026-07-24-flux-operator-migration-design.md`

**Reference cluster info (verified 2026-07-24):**
- `kubectl get nodes` shows 5 nodes (3 control-plane `whoverse-cp{1,2,3}`, 2 workers `whoverse-w{1,2}`) on k8s 1.36.2.
- `HelmRelease/flux2` is currently `True` at chart 2.19.0 (Flux 2.9.1).
- All 6 controllers (source, kustomize, helm, notification, image-reflector, image-automation) are running.
- No `FluxInstance` CRD installed yet.

---

## Task 1: Add HelmRepository/controlplaneio

**Files:**
- Create: `kubernetes/flux-config/registry/helm/controlplaneio.yaml`
- Modify: `kubernetes/flux-config/registry/helm/kustomization.yaml:18`

- [ ] **Step 1: Create the HelmRepository**

Write to `kubernetes/flux-config/registry/helm/controlplaneio.yaml`:

```yaml
---
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

- [ ] **Step 2: Add to registry kustomization**

Edit `kubernetes/flux-config/registry/helm/kustomization.yaml`. After line 11 (`- fluxcd-community.yaml`) add `- controlplaneio.yaml`. Final file:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - bjw-s.yaml
  - cilium.yaml
  - home-operations.yaml
  - home-operations-mirror.yaml
  - envoy-gateway.yaml
  - external-dns.yaml
  - external-secrets.yaml
  - fluxcd-community.yaml
  - controlplaneio.yaml
  - intel.yaml
  - jetstack.yaml
  - jellyfin.yaml
  - metrics-server.yaml
  - nfd.yaml
  - openebs.yaml
  - miroir.yaml
  - ceph-csi-operator.yaml
  - rook-ceph.yaml
  - spegel.yaml
  - tailscale.yaml
  - dex.yaml
  - victoria-metrics.yaml
  - grafana.yaml
  - vector.yaml
  - headlamp.yaml
  - sympozium.yaml
  - error-pages.yaml
```

- [ ] **Step 3: Validate the build**

Run:
```bash
kustomize build kubernetes/flux-config/registry/helm | kubeconform -strict -ignore-missing-schemas
```

Expected: exits 0, lists the new `HelmRepository/controlplaneio/flux-system`.

- [ ] **Step 4: Commit**

```bash
git add kubernetes/flux-config/registry/helm/controlplaneio.yaml \
        kubernetes/flux-config/registry/helm/kustomization.yaml
git commit -m "feat(flux): add controlplaneio HelmRepository for flux-operator"
```

---

## Task 2: Add the flux-operator component

**Files:**
- Create: `kubernetes/flux-system/flux-operator/ks.yaml`
- Create: `kubernetes/flux-system/flux-operator/app/helmrelease.yaml`
- Create: `kubernetes/flux-system/flux-operator/app/kustomization.yaml`

- [ ] **Step 1: Create the flux-operator Kustomization**

Write to `kubernetes/flux-system/flux-operator/ks.yaml`:

```yaml
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: flux-operator
  namespace: flux-system
spec:
  interval: 30m
  path: "./flux-system/flux-operator/app"
  sourceRef:
    kind: OCIRepository
    name: home-ops
  prune: false
  wait: true
  timeout: 5m
```

- [ ] **Step 2: Create the operator HelmRelease**

Write to `kubernetes/flux-system/flux-operator/app/helmrelease.yaml`:

```yaml
---
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: flux-operator
  namespace: flux-system
spec:
  interval: 30m
  chart:
    spec:
      chart: flux-operator
      version: 0.27.0
      sourceRef:
        kind: HelmRepository
        name: controlplaneio
        namespace: flux-system
      interval: 24h
  install:
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
    installCRDs: true
    resources:
      limits:
        cpu: 1000m
        memory: 512Mi
      requests:
        cpu: 100m
        memory: 64Mi
```

- [ ] **Step 3: Create the app kustomization**

Write to `kubernetes/flux-system/flux-operator/app/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - helmrelease.yaml
```

- [ ] **Step 4: Validate the build**

Run:
```bash
kustomize build kubernetes/flux-system/flux-operator/app | kubeconform -strict -ignore-missing-schemas
```

Expected: exits 0, lists `HelmRelease/flux-operator/flux-system`.

- [ ] **Step 5: Commit**

```bash
git add kubernetes/flux-system/flux-operator/
git commit -m "feat(flux): add flux-operator HelmRelease"
```

---

## Task 3: Add the flux-instance component

**Files:**
- Create: `kubernetes/flux-system/flux-instance/ks.yaml`
- Create: `kubernetes/flux-system/flux-instance/app/fluxinstance.yaml`
- Create: `kubernetes/flux-system/flux-instance/app/kustomization.yaml`

- [ ] **Step 1: Create the flux-instance Kustomization**

Write to `kubernetes/flux-system/flux-instance/ks.yaml`:

```yaml
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: flux-instance
  namespace: flux-system
spec:
  dependsOn:
    - name: flux-operator
  interval: 30m
  path: "./flux-system/flux-instance/app"
  sourceRef:
    kind: OCIRepository
    name: home-ops
  prune: false
  wait: true
  timeout: 5m
```

- [ ] **Step 2: Create the FluxInstance CR**

Write to `kubernetes/flux-system/flux-instance/app/fluxinstance.yaml`:

```yaml
---
apiVersion: fluxcd.controlplane.io/v1
kind: FluxInstance
metadata:
  name: flux
  namespace: flux-system
spec:
  distribution:
    # renovate: datasource=github-releases depName=controlplaneio-fluxcd/distribution
    version: "2.9.4"
    registry: "ghcr.io/fluxcd"
  components:
    - source-controller
    - kustomize-controller
    - helm-controller
    - notification-controller
    - image-reflector-controller
    - image-automation-controller
  cluster:
    size: medium
  kustomize:
    patches:
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

- [ ] **Step 3: Create the app kustomization**

Write to `kubernetes/flux-system/flux-instance/app/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - fluxinstance.yaml
```

- [ ] **Step 4: Validate the build**

Run:
```bash
kustomize build kubernetes/flux-system/flux-instance/app | kubeconform -strict -ignore-missing-schemas
```

Expected: exits 0, lists `FluxInstance/flux/flux-system`. (kubeconform may not know the `fluxcd.controlplane.io/v1` CRD schema; the `-ignore-missing-schemas` flag suppresses that warning.)

- [ ] **Step 5: Commit**

```bash
git add kubernetes/flux-system/flux-instance/
git commit -m "feat(flux): add FluxInstance replacing HelmRelease/flux2"
```

---

## Task 4: Wire components into the flux-system namespace kustomization

**Files:**
- Modify: `kubernetes/flux-system/kustomization.yaml:3-5`

- [ ] **Step 1: Update the flux-system kustomization**

Edit `kubernetes/flux-system/kustomization.yaml` to add the two new components. Final file:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ns.yaml
  - webhook/ks.yaml
  - flux-operator/ks.yaml
  - flux-instance/ks.yaml
```

- [ ] **Step 2: Validate**

Run:
```bash
kustomize build kubernetes/flux-system
```

Expected: includes `ns.yaml`, `webhook/ks.yaml`, `flux-operator/ks.yaml`, `flux-instance/ks.yaml`.

- [ ] **Step 3: Run pre-commit**

Run:
```bash
pre-commit run --files kubernetes/flux-system/kustomization.yaml kubernetes/flux-system/flux-operator/ks.yaml kubernetes/flux-system/flux-instance/ks.yaml
```

Expected: gitleaks + trufflehog pass (the AGENTS.md structure pre-commit hook only fires on `git commit`; structural rules are enforced by kustomize build succeeding).

- [ ] **Step 4: Commit**

```bash
git add kubernetes/flux-system/kustomization.yaml
git commit -m "feat(flux): wire flux-operator and flux-instance into flux-system ns"
```

---

## Task 5: Remove HelmRelease/flux2 and update flux-config

**Files:**
- Delete: `kubernetes/flux-config/flux-helmrelease.yaml`
- Modify: `kubernetes/flux-config/kustomization.yaml:6`
- Modify: `kubernetes/flux-config/flux-system.yaml:13-17`

- [ ] **Step 1: Delete HelmRelease/flux2**

Run:
```bash
git rm kubernetes/flux-config/flux-helmrelease.yaml
```

Expected: file removed from tracking, working tree clean.

- [ ] **Step 2: Remove the reference from flux-config kustomization**

Edit `kubernetes/flux-config/kustomization.yaml` to remove the line `- flux-helmrelease.yaml`. Final file:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - registries.yaml
  - flux-system.yaml
  - cluster.yaml
```

- [ ] **Step 3: Update flux-system healthcheck target**

Edit `kubernetes/flux-config/flux-system.yaml`. Replace the `healthChecks` block (lines 13-17) with:

```yaml
  healthChecks:
    - apiVersion: fluxcd.controlplane.io/v1
      kind: FluxInstance
      name: flux
      namespace: flux-system
    - apiVersion: helm.toolkit.fluxcd.io/v2
      kind: HelmRelease
      name: flux-operator
      namespace: flux-system
```

Final file:

```yaml
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: flux-system
  namespace: flux-system
spec:
  interval: 10m
  path: "./flux-config"
  sourceRef:
    kind: OCIRepository
    name: home-ops
  healthChecks:
    - apiVersion: fluxcd.controlplane.io/v1
      kind: FluxInstance
      name: flux
      namespace: flux-system
    - apiVersion: helm.toolkit.fluxcd.io/v2
      kind: HelmRelease
      name: flux-operator
      namespace: flux-system
  timeout: 10m
  wait: true
  prune: true
```

- [ ] **Step 4: Validate flux-config builds**

Run:
```bash
kustomize build kubernetes/flux-config | kubeconform -strict -ignore-missing-schemas -schema-location default -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
```

Expected: exits 0; output no longer contains `HelmRelease/flux2`; contains `Kustomization/flux-system` with the new healthchecks.

- [ ] **Step 5: Commit**

```bash
git add kubernetes/flux-config/flux-helmrelease.yaml kubernetes/flux-config/kustomization.yaml kubernetes/flux-config/flux-system.yaml
git commit -m "refactor(flux): remove HelmRelease/flux2, point healthcheck at FluxInstance"
```

---

## Task 6: Update bootstrap/helmfile.yaml to install flux-operator

**Files:**
- Modify: `kubernetes/bootstrap/helmfile.yaml:1-25`
- Delete: `kubernetes/bootstrap/flux-values.yaml`

- [ ] **Step 1: Delete flux-values.yaml**

Run:
```bash
git rm kubernetes/bootstrap/flux-values.yaml
```

Expected: file removed.

- [ ] **Step 2: Replace helmfile.yaml with operator-first version**

Write to `kubernetes/bootstrap/helmfile.yaml`:

```yaml
repositories:
  - name: cilium
    url: https://helm.cilium.io
  - name: controlplaneio
    url: ghcr.io/controlplaneio-fluxcd/charts
    oci: true

releases:
  # Cilium CNI - must be first for networking
  - name: cilium
    namespace: kube-system
    chart: cilium/cilium
    version: 1.19.6
    values:
      - cilium-values.yaml
    wait: true
    timeout: 300

  # Flux Operator - GitOps controller lifecycle (installs FluxInstance CRDs)
  - name: flux-operator
    namespace: flux-system
    chart: controlplaneio/flux-operator
    version: 0.27.0
    wait: true
    timeout: 300
```

- [ ] **Step 3: Validate the file is well-formed YAML**

Run:
```bash
helmfile --file kubernetes/bootstrap/helmfile.yaml build 2>&1 | head -20
```

Expected: exits 0; lists `cilium` and `flux-operator` releases. (`helmfile build` renders the chart values without contacting the cluster.)

- [ ] **Step 4: Commit**

```bash
git add kubernetes/bootstrap/helmfile.yaml kubernetes/bootstrap/flux-values.yaml
git commit -m "feat(bootstrap): install flux-operator via helmfile, drop flux2 release"
```

---

## Task 7: Remove obsolete bootstrap paths

**Files:**
- Delete: `kubernetes/bootstrap.sh`
- Modify: `Justfile:79-102`

- [ ] **Step 1: Delete bootstrap.sh**

Run:
```bash
git rm kubernetes/bootstrap.sh
```

Expected: file removed.

- [ ] **Step 2: Replace bootstrap-flux and flux-configure recipes**

Edit `Justfile`. Replace lines 79-102 (from `# Install Flux only` through `# Full bootstrap: Cilium + Flux + self-management config`) with:

```just
# Bootstrap Cilium and Flux Operator using Helmfile
bootstrap-helmfile:
    cd {{bootstrap_dir}} && helmfile apply

# Full bootstrap: Cilium + Flux Operator + Flux self-management via GitOps
bootstrap: bootstrap-helmfile bootstrap-sops-key
```

Note: `flux-configure` is no longer needed — once `bootstrap-helmfile` installs the operator, GitOps takes over (the `cluster` Kustomization applies `FluxInstance`, the operator reconciles it, and Flux controllers come online).

- [ ] **Step 3: Verify Justfile syntax**

Run:
```bash
just --list 2>&1 | head -30
```

Expected: lists recipes including `bootstrap`, `bootstrap-helmfile`, `bootstrap-sops-key`; no longer lists `bootstrap-flux` or `flux-configure`.

- [ ] **Step 4: Commit**

```bash
git add Justfile kubernetes/bootstrap.sh
git commit -m "refactor(bootstrap): delete bootstrap.sh and obsolete Justfile recipes"
```

---

## Task 8: Re-enable flux-local CI job

**Files:**
- Modify: `.github/workflows/validate-kubernetes.yml:79`

- [ ] **Step 1: Remove the `if: false` disable comment**

Edit `.github/workflows/validate-kubernetes.yml` line 79:

Change:
```yaml
    if: false  # temporarily disabled
```
to:
```yaml
    if: steps.filter.outputs.kubernetes == 'true'
```

(Note: `steps.filter` is defined earlier in the workflow at line 27. Using the same filter ensures the job runs only when kubernetes files change, matching the existing `kustomize-validate` gating pattern.)

- [ ] **Step 2: Add the filter dependency**

Find the `flux-local` job (lines 77-112). Add a `needs:` line referencing the filter output. Replace the job header block (lines 77-84) with:

```yaml
  flux-local:
    name: flux-local Test + Diff
    needs: [kustomize-validate]
    if: steps.filter.outputs.kubernetes == 'true' && needs.kustomize-validate.result == 'success'
    runs-on: ubuntu-latest
    permissions:
      contents: read
      pull-requests: write
    steps:
      - name: Checkout
        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7
        with:
          fetch-depth: 0
```

- [ ] **Step 3: Validate the workflow is well-formed**

Run:
```bash
yq -P '.jobs' .github/workflows/validate-kubernetes.yml | head -40
```

Expected: shows `kustomize-validate`, `ci`, and `flux-local` jobs; `flux-local` has `needs: [kustomize-validate]` and `if` referencing the filter.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/validate-kubernetes.yml
git commit -m "ci(flux): re-enable flux-local validation, gated on kustomize success"
```

---

## Task 9: Full local validation

**Files:** none (validation only)

- [ ] **Step 1: Validate the root aggregator**

Run:
```bash
kustomize build kubernetes | kubeconform -strict -ignore-missing-schemas -schema-location default -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
```

Expected: exits 0.

- [ ] **Step 2: Validate flux-config**

Run:
```bash
kustomize build kubernetes/flux-config | kubeconform -strict -ignore-missing-schemas -schema-location default -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
```

Expected: exits 0.

- [ ] **Step 3: Validate flux-system namespace**

Run:
```bash
kustomize build kubernetes/flux-system | kubeconform -strict -ignore-missing-schemas
```

Expected: exits 0.

- [ ] **Step 4: Validate operator app and instance app individually**

Run:
```bash
for path in kubernetes/flux-system/flux-operator/app kubernetes/flux-system/flux-instance/app; do
  echo "=== $path ==="
  kustomize build "$path" | kubeconform -strict -ignore-missing-schemas
done
```

Expected: each prints its HelmRelease / FluxInstance, exits 0.

- [ ] **Step 5: Run pre-commit on the whole tree**

Run:
```bash
pre-commit run --all-files
```

Expected: gitleaks and trufflehog pass on all tracked files.

- [ ] **Step 6: Run structure-rule check manually**

Run:
```bash
for ns_dir in kubernetes/*/; do
  ns=$(basename "$ns_dir")
  [ "$ns" = "components" ] && continue
  [ "$ns" = "scripts" ] && continue
  [ "$ns" = "flux-config" ] && continue
  [ "$ns" = "bootstrap" ] && continue
  [ -f "$ns_dir/ns.yaml" ] || { echo "MISSING: $ns_dir/ns.yaml"; continue; }
  first_resource=$(yq -r '.resources[0]' "$ns_dir/kustomization.yaml")
  [ "$first_resource" = "ns.yaml" ] || echo "ORDER: $ns_dir/kustomization.yaml does not start with ns.yaml"
done
```

Expected: no `MISSING` or `ORDER` lines printed for `flux-system`.

---

## Task 10: Build the OCI artifact and verify in-cluster

**Files:** none (deploy + verify)

- [ ] **Step 1: Build and push the OCI artifact**

Run:
```bash
just deploy
```

(`just deploy` runs `flux-push` (build OCI artifact) followed by `flux-sync` (annotate OCIRepository + reconcile cluster).) Expected: OCI artifact pushed to `oci://ghcr.io/alinanova21/home-ops:latest`.

- [ ] **Step 2: Verify HelmRepository reconciliation**

Run:
```bash
flux get helmrepositories -n flux-system
```

Expected: `controlplaneio` shows `Ready=True`.

- [ ] **Step 3: Verify HelmRelease/flux-operator**

Run:
```bash
kubectl get helmrelease -n flux-system flux-operator
```

Expected: `True` with message `Helm install succeeded for release flux-system/flux-operator.v1 with chart flux-operator-0.27.0`.

- [ ] **Step 4: Verify flux-operator Deployment**

Run:
```bash
kubectl get deployment -n flux-system flux-operator
kubectl get pods -n flux-system -l app=flux-operator
```

Expected: Deployment `Ready`, pods `Running`.

- [ ] **Step 5: Verify FluxInstance reconciliation**

Run:
```bash
kubectl get fluxinstance -n flux-system flux -o yaml | head -40
```

Expected: `.status.conditions[?(@.type=="Ready")].status == "True"`, message indicates Flux v2.9.3 components applied.

- [ ] **Step 6: Verify all Flux controllers**

Run:
```bash
kubectl get pods -n flux-system -l app.kubernetes.io/name -o wide
```

Expected: source-controller, kustomize-controller, helm-controller, notification-controller, image-reflector-controller, image-automation-controller all `Running` (old HelmRelease-managed pods will be replaced by FluxInstance-managed pods; expect a brief restart during reconcile).

- [ ] **Step 7: Confirm custom flags applied**

Run:
```bash
kubectl get deploy -n flux-system kustomize-controller -o jsonpath='{.spec.template.spec.containers[0].args}' | jq .
kubectl get deploy -n flux-system helm-controller -o jsonpath='{.spec.template.spec.containers[0].args}' | jq .
kubectl get deploy -n flux-system source-controller -o jsonpath='{.spec.template.spec.containers[0].args}' | jq .
```

Expected: kustomize-controller args contain `--concurrent=16` and `--requeue-dependency=5s`; helm-controller args contain `--concurrent=16` and `--requeue-dependency=5s`; source-controller args contain `--requeue-dependency=5s`.

- [ ] **Step 8: Run flux check**

Run:
```bash
flux check
```

Expected: all checks `✔`, controllers listed at v2.9.3.

- [ ] **Step 9: Verify the cluster Kustomization is healthy**

Run:
```bash
kubectl get kustomization -n flux-system cluster -o jsonpath='{.status.conditions[?(@.type=="Healthy")]}{"\n"}{.status.conditions[?(@.type=="Healthy")].message}{"\n"}'
```

Expected: `True` and references `HelmRelease/flux-operator` + `FluxInstance/flux` as healthy.

- [ ] **Step 10: Clean up the old HelmRelease/flux2**

Run:
```bash
kubectl delete helmrelease flux2 -n flux-system
```

Expected: deleted. (Flux will not recreate it since the file was removed from Git.) This is a safety cleanup — if the previous steps succeeded, this final removal ensures no orphaned resource remains.

---

## Task 11: Final commit and report

**Files:** none

- [ ] **Step 1: Confirm working tree state**

Run:
```bash
git status
```

Expected: working tree clean (only expected files modified).

- [ ] **Step 2: Summarize the migration**

Confirm:
- `kubernetes/flux-system/flux-operator/` contains `ks.yaml` and `app/helmrelease.yaml` + `app/kustomization.yaml`.
- `kubernetes/flux-system/flux-instance/` contains `ks.yaml` and `app/fluxinstance.yaml` + `app/kustomization.yaml`.
- `kubernetes/flux-config/flux-helmrelease.yaml` does not exist.
- `kubernetes/bootstrap/helmfile.yaml` installs cilium + flux-operator.
- `kubernetes/bootstrap.sh` does not exist.
- `Justfile` has no `bootstrap-flux` or `flux-configure` recipes.
- `.github/workflows/validate-kubernetes.yml` has `flux-local` re-enabled.
- Cluster runs Flux v2.9.3 managed by flux-operator v0.27.0, all 6 controllers Running, custom args applied.

Report any deviations to the user.
## Post-incident findings (2026-07-25)

### csi-snapshotter sidecar requires explicit snapshotPolicy
The ceph-csi-drivers chart v1.0.4 defaults `snapshotPolicy: none` which omits
the csi-snapshotter sidecar. This breaks the VolumeSnapshot → CSI → ceph RBD
chain. Set `snapshotPolicy: volumeSnapshot` in both `operatorConfig.driverSpecDefaults`
and per-driver spec in the HelmRelease values.

### csi-rbdplugin empty keyring after operator reconcile
After the csi-snapshotter sidecar is added, the csi-rbdplugin still fails with
"failed to fetch monitor list using clusterID (storage): missing configuration".
The ceph-csi-operator v1.0.4 does not mount the `rook-csi-rbd-provisioner` secret
to `/tmp/csi/keys/rbd` in its generated Deployment. Workaround: patch the
operator-managed Deployment to add an init container that copies the secret into
the emptyDir. This must be done once the operator is scaled down (otherwise its
reconcile loop reverts the change).
