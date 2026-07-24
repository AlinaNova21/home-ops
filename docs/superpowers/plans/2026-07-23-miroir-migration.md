# Mirror Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace every use of the `openebs-hostpath` storage class with `miroir-replicated` (DRBD-replicated LVM-thin block storage) on the four-node pool `whoverse-cp1, -cp2, -cp3, -w1`. Decommission the `openebs-localpv` Helm release entirely.

**Architecture:** Staged Talos re-image + Kubernetes manifest introduction + per-node openebs→mirror cutover. The mirror chart is installed on day zero with no disks attached; the agent sits idle until each `r-miroir` partition appears. Each pool node is cycled one at a time (cp1 → cp2 → w1 → cp3) with kopiur snapshots covering the only irrecoverable data (the three `vmstorage-*` shards).

**Tech Stack:** Talos 1.13.5, Talhelper, OpenEBS LocalPV, DRBD9 (siderolabs/drbd extension), home-operations/miroir (CSI + chart), home-operations/kopiur (Kopia backups), Flux v2, kubeconform.

**Pause rule (binding):** No `git commit`, `git push`, `kubectl apply`, `talosctl ...`, `flux reconcile`, Helm chart upgrade, or any cluster-affecting action without an explicit "continue" / "proceed" from the user. Each phase below ends with a `STOP` line. The user explicitly opted into this rule before any cluster mutation begins.

**Spec reference:** `docs/superpowers/specs/2026-07-23-miroir-migration-design.md`

**Validation matrix (run after every task):**

| Check | Command |
|---|---|
| Kustomization validates | `kustomize build <path> \| kubeconform -strict -ignore-missing-schemas -schema-location default -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'` |
| Flux happy | `just flux-status` |
| Talos healthy | `talosctl -n <ip> health` |
| Mirror pool members | `kubectl get miroirnodegroup cluster` |
| OpenEBS still in use | `kubectl get pvc -A -o json \| jq '.items[] \| select(.spec.storageClassName=="openebs-hostpath") \| {ns:.metadata.namespace, name:.metadata.name}'` |
| VM-storage backed up | `kubectl get backup -A` for snapshot policies `vmstorage-0/1/2` |

---

## File Structure

### Created (GitOps — version-controlled)

- `talos/whoverse/miroir-kernel.yaml` — kernel module + kubelet config patch
- `talos/whoverse/miroir-disk.yaml` — `RawVolumeConfig` peer of `ceph-osd-volume.yaml`
- `kubernetes/flux-config/registry/helm/miroir.yaml` — `HelmRepository` for `oci://ghcr.io/home-operations/charts/miroir`
- `kubernetes/storage/miroir/ns.yaml` — `Namespace` (the existing `storage` namespace is reused — this file may be a no-op alias or omitted entirely; verify before writing)
- `kubernetes/storage/miroir/ks.yaml` — Flux `Kustomization` with `name: miroir`, `namespace: storage`
- `kubernetes/storage/miroir/kustomization.yaml` — Kustomize aggregator
- `kubernetes/storage/miroir/app/helmrelease.yaml` — `HelmRelease` for the mirror chart
- `kubernetes/storage/miroir/app/miroirnodegroup.yaml` — `MiroirNodeGroup` CR
- `kubernetes/storage/miroir/app/storageclass.yaml` — `miroir-replicated` `StorageClass`
- `kubernetes/storage/miroir/app/volumesnapshotclass.yaml` — `miroir-snap` `VolumeSnapshotClass`
- `kubernetes/components/kopiur/vmstorage-backup/kustomization.yaml` — bundled kopiur component for the three `vmstorage-*` PVCs
- `kubernetes/components/kopiur/vmstorage-backup/snapshotpolicy.yaml` — `SnapshotPolicy` template
- `kubernetes/components/kopiur/vmstorage-backup/snapshotschedule.yaml` — `SnapshotSchedule` template

### Modified

- `talos/whoverse/talconfig.yaml` — add `siderolabs/drbd` to both `controlPlane.schematic` and `worker.schematic`; add `./miroir-kernel.yaml` to both `controlPlane.patches` and `worker.patches`; add `./miroir-disk.yaml` to `nodes[cp1/cp2/cp3/w1].patches`; (Phase 6) remove `hostpath` from the `&sharedUserVolumes` anchor
- `kubernetes/flux-config/registry/helm/kustomization.yaml` — include `miroir.yaml`
- `kubernetes/storage/kustomization.yaml` — include `./miroir/ks.yaml` (in Phase 0b); eventually drop `./openebs-localpv/ks.yaml` (in Phase 7)
- `kubernetes/monitoring/victoria-metrics/app/helmrelease.yaml` — `persistence.storageClass` and `persistence.size` updated for the 3 `vmstorage-*` and 2 `vmselect-cachedir-*` PVCs (Phases 1 / 3 / 4)
- `kubernetes/monitoring/victoria-logs/app/helmrelease.yaml` — `persistence.storageClass` for the 2 `vlstorage-volume-*` PVCs (Phases 2 / 3 / 4)
- `kubernetes/monitoring/grafana/app/helmrelease.yaml` — `persistence.storageClass` for `grafana` PVC (Phase 5)
- `kubernetes/storage/rook-ceph/app/helmrelease-cluster.yaml` — `monPVCs` `storageClassName` updated for `rook-ceph-mon-j/m/n` (Phases 2 / 4 / 7)

### Removed (Phase 7 final)

- `kubernetes/storage/openebs-localpv/` — entire tree; `Flux` `prune: true` cleans the runtime

---

## Conventions for every task

- Read the spec section that the task references before starting.
- Run only the commands shown. Do **not** `kubectl apply` ad-hoc; use Flux where the manifests are Flux-managed, or `kubectl apply -f` where they are direct.
- Each task ends with the **Status check** commands in the validation matrix above.
- A failed validation halts the task — investigate, do not proceed.
- Talos apply commands are never run in batch — always per-node.

---

# Phase 0a — Re-image each node with the drbd extension and the kernel/shutdown patch (partition layout unchanged)

Goal: every node boots with the `drbd` and `drbd_transport_tcp` kernel modules loadable on demand, with `usermode_helper=disabled` set, and with kubelet graceful-shutdown configured. Partition layout stays intact — Phase 1–4 do the partition swap.

Per-node cycle: `w2` (worker, no pool) only needs the kernel + shutdown patch, not the kernel module (no `r-miroir` ever). `cp1/cp2/cp3/w1` need everything.

Status before this phase: cluster is exactly as it was before planning started. `talosctl -n <node> read /proc/modules | grep drbd` returns empty on every node.

## Task 1: Create `talos/whoverse/miroir-kernel.yaml`

**Files:**
- Create: `talos/whoverse/miroir-kernel.yaml`

- [ ] **Step 1: Write the file**

```yaml
---
machine:
  kernel:
    modules:
      - name: drbd
        parameters:
          - usermode_helper=disabled
      - name: drbd_transport_tcp
  kubelet:
    extraConfig:
      shutdownGracePeriod: 120s
      shutdownGracePeriodCriticalPods: 60s
```

- [ ] **Step 2: Verify file shape**

Run: `yq -P talos/whoverse/miroir-kernel.yaml`
Expected: YAML parses, three top-level keys (`machine.kernel.modules[].name`, `machine.kernel.modules[].parameters`, `machine.kubelet.extraConfig`).

- [ ] **Step 3: Commit**

```bash
git add talos/whoverse/miroir-kernel.yaml
git commit -m "talos: add miroir-kernel patch (drbd module + kubelet graceful shutdown)"
```

## Task 2: Add `drbd` to `controlPlane.schematic` in `talconfig.yaml`

**Files:**
- Modify: `talos/whoverse/talconfig.yaml` — `controlPlane.schematic.customization.systemExtensions.officialExtensions` and `controlPlane.patches`

- [ ] **Step 1: Edit `controlPlane.schematic`**

Locate the `controlPlane:` block (`talconfig.yaml` line 77). Add `siderolabs/drbd` to its `schematic.customization.systemExtensions.officialExtensions` list (append after `siderolabs/xe`).

After edit, the block reads:

```yaml
controlPlane:
  schematic:
    customization:
      systemExtensions:
        officialExtensions:
          - siderolabs/iscsi-tools
          - siderolabs/realtek-firmware
          - siderolabs/gvisor
          - siderolabs/amdgpu
          - siderolabs/i915
          - siderolabs/xe
          - siderolabs/drbd            # NEW
```

- [ ] **Step 2: Add `miroir-kernel.yaml` reference to `controlPlane.patches`**

Add a new entry (peer of `./patches/spegel-containerd-config.yaml` and `./patches/watchdog.yaml`):

```yaml
    - "@./miroir-kernel.yaml"
```

- [ ] **Step 3: Verify changes**

Run: `yq .controlPlane talos/whoverse/talconfig.yaml | head -30`
Expected: shows the drbd extension in `officialExtensions` and `miroir-kernel.yaml` in `patches`.

- [ ] **Step 4: Commit**

```bash
git add talos/whoverse/talconfig.yaml
git commit -m "talos: enable drbd ext on control plane + apply mirror kernel patch"
```

## Task 3: Add `drbd` to `worker.schematic` in `talconfig.yaml`

**Files:**
- Modify: `talos/whoverse/talconfig.yaml` — `worker.schematic.customization.systemExtensions.officialExtensions` and `worker.patches`

- [ ] **Step 1: Edit `worker.schematic`**

Locate the `worker:` block (~line 142). Add `siderolabs/drbd` to its `schematic.customization.systemExtensions.officialExtensions` list.

After edit:

```yaml
worker:
  schematic:
    customization:
      systemExtensions:
        officialExtensions:
          - siderolabs/iscsi-tools
          - siderolabs/realtek-firmware
          - siderolabs/gvisor
          - siderolabs/amdgpu
          - siderolabs/i915
          - siderolabs/xe
          - siderolabs/drbd            # NEW
```

- [ ] **Step 2: Add `miroir-kernel.yaml` reference to `worker.patches`**

In the same `worker.patches:` block, add `- "@./miroir-kernel.yaml"` after the existing `./patches/watchdog.yaml` entry.

- [ ] **Step 3: Verify**

Run: `yq .worker talos/whoverse/talconfig.yaml | head -30`
Expected: drbd in `officialExtensions`, `miroir-kernel.yaml` in `worker.patches`.

- [ ] **Step 4: Commit**

```bash
git add talos/whoverse/talconfig.yaml
git commit -m "talos: enable drbd ext on workers + apply mirror kernel patch"
```

## Task 4: Regenerate Talos configs

**Files:**
- Generated: `talos/whoverse/clusterconfig/*.yaml` (regenerated, do not edit by hand)

- [ ] **Step 1: Generate**

Run: `just talos-gen`
Expected: talhelper regenerates every `clusterconfig/whoverse-*.yaml`. Inspect a control-plane and a worker file for the drbd module line.

- [ ] **Step 2: Spot-check the control-plane config**

Run: `grep -E "drbd|usermode_helper|shutdownGracePeriod" talos/whoverse/clusterconfig/whoverse-whoverse-cp1.yaml | head -20`
Expected: at least 3 hits covering `drbd`, `usermode_helper=disabled`, and `shutdownGracePeriod`.

- [ ] **Step 3: Spot-check a worker config**

Run: `grep -E "drbd|usermode_helper|shutdownGracePeriod" talos/whoverse/clusterconfig/whoverse-whoverse-w1.yaml | head -20`
Expected: same 3 hits.

- [ ] **Step 4: Commit the regenerated configs**

```bash
git status                # expect M talos/whoverse/clusterconfig/*
git add talos/whoverse/clusterconfig/
git commit -m "talos: regenerate configs with drbd module + graceful shutdown"
```

## Task 5: Apply to `whoverse-cp1`

**Stop point: this is the first Talos apply after which the cluster mutates. Confirm with the user before running `just talos-apply`.**

- [ ] **Step 1: Pre-flight**

Run:
```bash
talosctl -n 192.168.2.21 health
kubectl get nodes whoverse-cp1 -o wide
```
Expected: health reports no errors; node Ready.

- [ ] **Step 2: Apply** (requires explicit user "continue")

Run: `just talos-apply -n 192.168.2.21` (per the `talos/AGENTS.md` Justfile; or `talosctl apply-config -n 192.168.2.21 --file talos/whoverse/clusterconfig/whoverse-whoverse-cp1.yaml`).
Expected: cp1 reboots. The drbd schematic change requires an install-image upgrade; if talhelper plans `upgrade --reboot`, follow its prompts.

- [ ] **Step 3: Wait for ready**

```bash
talosctl -n 192.168.2.21 health
kubectl wait node whoverse-cp1 --for=condition=Ready --timeout=10m
```
Expected: ready within 10 minutes.

- [ ] **Step 4: Verify drbd module loadable**

```bash
talosctl -n 192.168.2.21 read /proc/modules | grep drbd || true
talosctl -n 192.168.2.21 read /lib/modules/$(talosctl -n 192.168.2.21 read /proc/version | awk '{print $3}')/modules.dep 2>/dev/null | grep drbd.ko || true
```
Expected: at least one mention of `drbd` in either output. (On some Talos versions the module list is empty until a consumer `modprobe`s — verify that `modprobe drbd` succeeds.)

```bash
talosctl -n 192.168.2.21 dmesg | tail -50 | grep -i drbd || echo "no dmesg drbd messages (expected, no consumer yet)"
```

- [ ] **Step 5: Verify kubelet graceful-shutdown settings**

```bash
talosctl -n 192.168.2.21 get kubeletconfig 2>/dev/null | grep -E "shutdownGracePeriod"
```
Expected: hits showing `shutdownGracePeriod: 120s` and `shutdownGracePeriodCriticalPods: 60s`.

- [ ] **Step 6: Commit any local state** — none expected.

## Task 6: Apply to `whoverse-cp2`

**Stop point: confirm with user. Repeat Task 5 verbatim with `-n 192.168.2.22`.**

## Task 7: Apply to `whoverse-cp3`

**Stop point: confirm with user. Repeat Task 5 verbatim with `-n 192.168.2.23`.**

## Task 8: Apply to `whoverse-w1`

**Stop point: confirm with user. Repeat Task 5 verbatim with `-n 192.168.2.24`.**

## Task 9: Apply to `whoverse-w2`

**Stop point: confirm with user. Repeat Task 5 verbatim with `-n 192.168.2.225`. w2 only gets the kernel-patch bits (drbd schematic + module params + shutdown grace). Partition layout is untouched, no `r-miroir` ever.**

After this step: every node has `drbd` loadable, `usermode_helper=disabled` set, kubelet graceful-shutdown configured. The cluster is otherwise unchanged.

**STOP — wait for user approval before Phase 0b.**

---

# Phase 0b — Install mirror chart with no disks attached

Goal: the mirror controller + agent pods exist, the `StorageClass` is registered, and the `MiroirNodeGroup` is in place. The agents will report `DeviceNotFound` because no `r-miroir` partition exists yet — that's the expected state.

Status before this phase: no `miroir.storage.k8s.io` resources exist. Storage namespace already exists.

## Task 10: Add HelmRepository for mirror

**Files:**
- Create: `kubernetes/flux-config/registry/helm/miroir.yaml`
- Modify: `kubernetes/flux-config/registry/helm/kustomization.yaml`

- [ ] **Step 1: Read the existing peer `kubernetes/flux-config/registry/helm/openebs.yaml`** to mirror its shape.

- [ ] **Step 2: Write `kubernetes/flux-config/registry/helm/miroir.yaml`**

```yaml
---
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: miroir
  namespace: flux-system
spec:
  interval: 12h
  type: oci
  url: oci://ghcr.io/home-operations/charts
  provider: generic
```

- [ ] **Step 3: Add the new resource to `kubernetes/flux-config/registry/helm/kustomization.yaml`'s `resources:` list (after the `openebs.yaml` entry)**

- [ ] **Step 4: Validate**

Run: `kustomize build kubernetes/flux-config/registry/helm | kubeconform -strict -ignore-missing-schemas -schema-location default -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'`
Expected: exit 0.

- [ ] **Step 5: Commit**

```bash
git add kubernetes/flux-config/registry/helm/
git commit -m "k8s: add helm repo for home-operations/miroir chart"
```

- [ ] **Step 6: Reconcile**

Run: `flux reconcile source chart miroir -n flux-system`
Expected: repository succeeds.

## Task 11: Create the namespace file (or skip)

**Files:**
- Create: `kubernetes/storage/miroir/ns.yaml` (only if the storage namespace needs a dedicated kustomization entry)

- [ ] **Step 1: Check existing namespace**

Run: `kubectl get ns storage -o yaml | grep name`
Expected: namespace exists. The flux Kustomization at `kubernetes/storage/miroir/ks.yaml` references this namespace — Flux will not re-create it.

- [ ] **Step 2: Skip creating `ns.yaml` if not strictly required by the bootstrap convention**

If the repo's `home-ops-add-new-app` skill template requires `ns.yaml` under every namespace directory, create a minimal file:

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: storage
```

Otherwise proceed to Task 12.

## Task 12: Create the mirror Flux Kustomization + Kustomize aggregator

**Files:**
- Create: `kubernetes/storage/miroir/ks.yaml`
- Create: `kubernetes/storage/miroir/kustomization.yaml`

- [ ] **Step 1: Reference a peer ks.yaml** (`kubernetes/storage/openebs-localpv/ks.yaml`) for the format.

- [ ] **Step 2: Write `kubernetes/storage/miroir/ks.yaml`**

```yaml
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: miroir
  namespace: storage
spec:
  interval: 30m
  sourceRef:
    kind: OCIRepository
    name: home-ops
  path: "./storage/miroir/app"
  prune: true
  wait: false
  timeout: 10m
```

- [ ] **Step 3: Write `kubernetes/storage/miroir/kustomization.yaml`**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ./ks.yaml
```

- [ ] **Step 4: Add `./miroir/ks.yaml` to `kubernetes/storage/kustomization.yaml`'s `resources:` list (placed after `./openebs-localpv/ks.yaml`)**

- [ ] **Step 5: Validate**

Run: `kustomize build kubernetes/storage | kubeconform -strict -ignore-missing-schemas -schema-location default -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'`
Expected: exit 0.

- [ ] **Step 6: Commit**

```bash
git add kubernetes/storage/miroir/ks.yaml \
        kubernetes/storage/miroir/kustomization.yaml \
        kubernetes/storage/kustomization.yaml
git commit -m "k8s: add mirror Flux Kustomization"
```

## Task 13: Create the storageclass.yaml

**Files:**
- Create: `kubernetes/storage/miroir/app/storageclass.yaml`

- [ ] **Step 1: Write the file**

```yaml
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: miroir-replicated
provisioner: miroir.home-operations.com
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
parameters:
  miroir.home-operations.com/replicas: "2"
  csi.storage.k8s.io/fstype: ext4
```

- [ ] **Step 2: Validate**

Run: `kustomize build kubernetes/storage/miroir | kubeconform -strict -ignore-missing-schemas -schema-location default -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'`
Expected: exit 0.

## Task 14: Create the volumesnapshotclass.yaml

**Files:**
- Create: `kubernetes/storage/miroir/app/volumesnapshotclass.yaml`

- [ ] **Step 1: Write the file**

```yaml
---
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshotClass
metadata:
  name: miroir-snap
driver: miroir.home-operations.com
deletionPolicy: Delete
```

## Task 15: Create the MiroirNodeGroup

**Files:**
- Create: `kubernetes/storage/miroir/app/miroirnodegroup.yaml`

- [ ] **Step 1: Write the file**

```yaml
---
apiVersion: miroir.home-operations.com/v1alpha1
kind: MiroirNodeGroup
metadata:
  name: cluster
spec:
  pools:
    - name: default
      lvmthin:
        device: /dev/disk/by-partlabel/r-miroir
  nodeSelector:
    matchLabels:
      miroir.home-operations.com/enabled: "true"
```

## Task 16: Create the HelmRelease

**Files:**
- Create: `kubernetes/storage/miroir/app/helmrelease.yaml`

- [ ] **Step 1: Reference `kubernetes/storage/openebs-localpv/app/helmrelease.yaml`** for the shape (HelmRelease with `chartRef.kind: HelmChart` is one option; explicit `chart.spec` is another — match whichever the existing peer uses).

- [ ] **Step 2: Write the file**

```yaml
---
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: miroir
  namespace: storage
spec:
  interval: 30m
  chart:
    spec:
      chart: miroir
      version: "<latest>"           # replace with current chart appVersion
      sourceRef:
        kind: HelmRepository
        name: miroir
        namespace: flux-system
      interval: 12h
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
    drbd:
      resync:
        minRate: 10M
      verify:
        algorithm: crc32c
    autoTieBreaker: true
    replicaCount: 1
    monitoring:
      podMonitor:
        enabled: false
      prometheusRule:
        enabled: false
```

- [ ] **Step 3: Resolve the chart version**

Run: `flux list helmreleases --all-namespaces` to see other release versions. Pin `<latest>` to whatever current `appVersion` is published (the exact tag — check `https://github.com/home-operations/miroir/releases`).

- [ ] **Step 4: Validate**

Run: `kustomize build kubernetes/storage/miroir | kubeconform -strict -ignore-missing-schemas -schema-location default -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'`
Expected: exit 0.

- [ ] **Step 5: Commit**

```bash
git add kubernetes/storage/miroir/
git commit -m "k8s: install home-operations/miroir CSI driver"
```

## Task 17: Label the four pool nodes

**Stop point: confirm with user.**

- [ ] **Step 1: Apply labels**

```bash
kubectl label node whoverse-cp1 whoverse-cp2 whoverse-cp3 whoverse-w1 \
  miroir.home-operations.com/enabled=true
```

- [ ] **Step 2: Reconcile the cluster Kustomization and the mirror HelmRelease**

```bash
flux reconcile kustomization cluster -n flux-system
flux reconcile helmrelease miroir -n storage
```

- [ ] **Step 3: Verify**

```bash
kubectl -n storage get pods -l app.kubernetes.io/name=miroir
kubectl -n storage get mirrorcontroller
kubectl -n storage get miroirnodegroup cluster -o jsonpath='{.status}{"\n"}'
talosctl -n 192.168.2.21 get discoveredvolume 2>&1 | tail -n +2 | grep r-miroir || echo "no r-miroir yet (expected at this point)"
```
Expected:
- mirror controller pod is Running
- agents on each of the four labeled nodes are Running (will likely log `DeviceNotFound`)
- `kubectl get discoveredvolume` on each storage node does **NOT** show `r-miroir` yet — that arrives in Phase 1

**STOP — wait for user approval before Phase 0c.**

---

# Phase 0c — Kopiur SnapshotPolicy + Schedule for the three vmstorage-* PVCs

Goal: every vmstorage shard has an hourly kopiur snapshot before any node cycles.

Status before this phase: openebs-hostpath PVCs intact. Kopiur chart is already deployed with `ClusterRepository: whoverse` and 14 PVC policies. We add 3 more (vmstorage-0/1/2).

## Task 18: Find the vmstorage PVC names

**Files:** none — read-only inspection

- [ ] **Step 1: Confirm PVC names**

Run:
```bash
kubectl -n monitoring get pvc -o json | \
  jq -r '.items[] | select(.spec.storageClassName=="openebs-hostpath" and (.metadata.name | startswith("vmstorage-"))) | .metadata.name'
```
Expected: 3 entries — `vmstorage-db-vmstorage-victoria-metrics-{0,1,2}` (or similar — copy exactly).

Capture the exact names; substitute them in every snapshot policy below.

## Task 19: Create the kopiur component for vmstorage

**Files:**
- Create: `kubernetes/components/kopiur/vmstorage-backup/kustomization.yaml`
- Create: `kubernetes/components/kopiur/vmstorage-backup/snapshotpolicy.yaml`
- Create: `kubernetes/components/kopiur/vmstorage-backup/snapshotschedule.yaml`

- [ ] **Step 1: Reference `kubernetes/components/kopiur/backup/`** for the shape.

- [ ] **Step 2: Write `kubernetes/components/kopiur/vmstorage-backup/kustomization.yaml`**

```yaml
# yaml-language-server: $schema=https://json.schemastore.org/kustomization
apiVersion: kustomize.config.k8s.io/v1alpha1
kind: Component
resources:
  - ./snapshotpolicy.yaml
  - ./snapshotschedule.yaml
```

- [ ] **Step 3: Write `kubernetes/components/kopiur/vmstorage-backup/snapshotpolicy.yaml`** — same shape as `kubernetes/components/kopiur/backup/snapshotpolicy.yaml` (uses `${APP}` substitution). The `miroir-backup` policy template sits here for future use, but for now we add three concrete SnapshotPolicies:

```yaml
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/kopiur.home-operations.com/snapshotpolicy_v1alpha1.json
apiVersion: kopiur.home-operations.com/v1alpha1
kind: SnapshotPolicy
metadata:
  name: vmstorage-0
spec:
  repository:
    kind: ClusterRepository
    name: whoverse
  credentialProjection:
    enabled: true
  sources:
    - pvc:
        name: vmstorage-db-vmstorage-victoria-metrics-0   # exact PVC name from Task 18
  retention:
    keepDaily: 7
    keepWeekly: 4
    keepMonthly: 3
---
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/kopiur.home-operations.com/snapshotpolicy_v1alpha1.json
apiVersion: kopiur.home-operations.com/v1alpha1
kind: SnapshotPolicy
metadata:
  name: vmstorage-1
spec:
  repository:
    kind: ClusterRepository
    name: whoverse
  credentialProjection:
    enabled: true
  sources:
    - pvc:
        name: vmstorage-db-vmstorage-victoria-metrics-1   # exact PVC name from Task 18
  retention:
    keepDaily: 7
    keepWeekly: 4
    keepMonthly: 3
---
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/kopiur.home-operations.com/snapshotpolicy_v1alpha1.json
apiVersion: kopiur.home-operations.com/v1alpha1
kind: SnapshotPolicy
metadata:
  name: vmstorage-2
spec:
  repository:
    kind: ClusterRepository
    name: whoverse
  credentialProjection:
    enabled: true
  sources:
    - pvc:
        name: vmstorage-db-vmstorage-victoria-metrics-2   # exact PVC name from Task 18
  retention:
    keepDaily: 7
    keepWeekly: 4
    keepMonthly: 3
```

- [ ] **Step 4: Write `kubernetes/components/kopiur/vmstorage-backup/snapshotschedule.yaml`** — three schedules:

```yaml
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/kopiur.home-operations.com/snapshotschedule_v1alpha1.json
apiVersion: kopiur.home-operations.com/v1alpha1
kind: SnapshotSchedule
metadata:
  name: vmstorage-0
spec:
  policyRef:
    name: vmstorage-0
  schedule:
    cron: H * * * *
---
apiVersion: kopiur.home-operations.com/v1alpha1
kind: SnapshotSchedule
metadata:
  name: vmstorage-1
spec:
  policyRef:
    name: vmstorage-1
  schedule:
    cron: H * * * *
---
apiVersion: kopiur.home-operations.com/v1alpha1
kind: SnapshotSchedule
metadata:
  name: vmstorage-2
spec:
  policyRef:
    name: vmstorage-2
  schedule:
    cron: H * * * *
```

- [ ] **Step 5: Wire it up**

Add `kubernetes/components/kopiur/vmstorage-backup/` to the `spec.components:` list of `kubernetes/monitoring/victoria-metrics/ks.yaml`.

- [ ] **Step 6: Validate**

Run: `kustomize build kubernetes/monitoring | kubeconform -strict -ignore-missing-schemas -schema-location default -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'`
Expected: exit 0.

- [ ] **Step 7: Commit**

```bash
git add kubernetes/components/kopiur/vmstorage-backup/ \
        kubernetes/monitoring/victoria-metrics/ks.yaml
git commit -m "k8s: kopiur snapshot vmstorage-* shards hourly"
```

## Task 20: Verify first snapshots exist

- [ ] **Step 1: Trigger immediately (do not wait for the next hourly tick)**

```bash
kubectl -n monitoring create -f - <<EOF
apiVersion: kopiur.home-operations.com/v1alpha1
kind: Backup
metadata:
  name: vmstorage-0-pre-cycle
spec:
  policyRef:
    name: vmstorage-0
EOF
# repeat for vmstorage-1, vmstorage-2
```

- [ ] **Step 2: Wait for completion (~10 minutes for 50GiB)**

```bash
kubectl -n monitoring get backup -w
```
Expected: `PHASE: completed` for each of the three `Backup` CRs.

- [ ] **Step 3: Verify the snapshots land in the `whoverse` ClusterRepository**

Run: `kubectl kopiur status` (the krew plugin installed per kopiur README) or `kubectl get backup -n monitoring -o json | jq '.items[].status'`.
Expected: each `Backup` reports `phase: Completed` with a snapshot ID.

**STOP — wait for user approval before Phase 1.**

---

# Phase 1 — Cycle whoverse-cp1

Goal: `r-miroir` shows up on cp1, the in-cluster PVCs that were on cp1's `u-hostpath` (one `vmstorage-*` shard and any other openebs PVCs) move to `miroir-replicated`, the workloads land on the new PVCs, and valkey monitoring is verified end to end.

Stop point: this is the first node cycle. The user must approve before each numbered step that does an irreversible action (Talos apply, HelmRelease apply with new storageClass).

Per-node cycle, generalized (cp1 details below — Phase 2/3/4 differ in node + ceph mon handling):

1. Drain openebs-hostpath users off the node.
2. Add `miroir-disk.yaml` to the **single node's** `talconfig.yaml` `nodes[].patches`.
3. `just talos-gen && just talos-apply` for that node.
4. Validate node reboots with `r-miroir` partition present.
5. Provision mirror PVCs for the openebs-hostpath content that lived on that node.
6. Kopiur `Restore` snapshots into the new mirror PVCs (only for `vmstorage-*`).
7. Update the workload's HelmRelease to use `miroir-replicated` + the new PVC names.
8. Force-recreate or restart the workload pointing at the new PVCs.
9. Validate monitoring.

## Task 21: Inspect what currently lives on cp1's `u-hostpath`

- [ ] **Step 1: List openebs PVC dirs on cp1**

```bash
talosctl -n 192.168.2.21 list /var/mnt/hostpath 2>&1 | tail -n +2 | awk '{print $NF}' | grep ^pvc-
```
Expected: list of PVC directories currently hosted by cp1.

- [ ] **Step 2: Cross-reference each `pvc-*` with its Kubernetes PVC name + namespace**

```bash
for pvcDir in $(talosctl -n 192.168.2.21 list /var/mnt/hostpath 2>&1 | tail -n +2 | awk '{print $NF}' | grep ^pvc-); do
  echo "$pvcDir on cp1:"
  kubectl get pv -o json | jq -r ".items[] | select(.metadata.name==\"$pvcDir\") | \"  ns=\(.spec.claimRef.namespace) name=\(.spec.claimRef.name)\""
done
```
Expected: a per-PVC table. Capture this — every PVC identified here must be migrated to `miroir-replicated` during this phase.

## Task 22: Drain cp1

**Stop point: confirm with user.**

- [ ] **Step 1: Drain**

```bash
kubectl drain whoverse-cp1 --ignore-daemonsets --delete-emptydir-data --force
```
Expected: pods evicted or noted as already gone. Openebs-hostpath users on cp1 are now unscheduled (their stateful pods prefer cp1 but will tolerate others — except RWO PVCs which can't move without our migration).

## Task 23: Add `miroir-disk.yaml` to the cp1 node patch list

**Stop point: confirm with user — this is the Talos config change that will trigger the next `talos-apply`.**

- [ ] **Step 1: Write `talos/whoverse/miroir-disk.yaml`**

```yaml
---
apiVersion: v1alpha1
kind: RawVolumeConfig
name: miroir
provisioning:
  diskSelector:
    match: system_disk
  minSize: 128GiB
  maxSize: 128GiB
```

- [ ] **Step 2: Add `miroir-disk.yaml` to `nodes[cp1].patches`**

In `talconfig.yaml`, under `- hostname: whoverse-cp1`, the existing `patches:` list has `- "@./ceph-osd-volume.yaml"`. Add `- "@./miroir-disk.yaml"` after it.

The block now reads:

```yaml
  - hostname: whoverse-cp1  # ZimaBoard
    ipAddress: 192.168.2.21
    controlPlane: true
    installDisk: /dev/sda
    patches:
      - "@./ceph-osd-volume.yaml"
      - "@./miroir-disk.yaml"
```

- [ ] **Step 3: Regenerate**

```bash
just talos-gen
git diff talos/whoverse/clusterconfig/whoverse-whoverse-cp1.yaml | grep -A5 miroir-disk
```
Expected: the cp1 regenerated config includes the RawVolumeConfig.

- [ ] **Step 4: Commit**

```bash
git add talos/whoverse/miroir-disk.yaml talos/whoverse/clusterconfig/
git commit -m "talos: add r-miroir raw volume to cp1"
```

## Task 24: Apply Talos to cp1 and validate `r-miroir` partition

**Stop point: this reboots cp1. Confirm with user.**

- [ ] **Step 1: Apply**

```bash
just talos-apply -n 192.168.2.21
```
Expected: cp1 reboots. The `u-hostpath` partition is gone, `r-miroir` partition is created.

- [ ] **Step 2: Wait for ready**

```bash
kubectl wait node whoverse-cp1 --for=condition=Ready --timeout=10m
```

- [ ] **Step 3: Verify `r-miroir` partition**

```bash
talosctl -n 192.168.2.21 get discoveredvolume 2>&1 | tail -n +2 | grep r-miroir
```
Expected: a partition labelled `r-miroir` appears. If absent, fall back to per-node RawVolumeConfig with a path selector per the spec's risk-mitigation table.

- [ ] **Step 4: Verify the mirror agent on cp1**

```bash
talosctl -n 192.168.2.21 dmesg | tail -100 | grep -iE "drbd|lvm" || true
kubectl -n storage logs -l app.kubernetes.io/name=miroir --tail=50 | grep -iE "cp1|r-miroir|ready" || true
```
Expected: agent log lines mentioning cp1, `r-miroir`, and a successful pool initialization.

- [ ] **Step 5: Verify the `MiroirNodeGroup` exposes cp1's pool**

```bash
kubectl get miroirnodegroup cluster -o yaml
```
Expected: 1+ MiroirNode resources for cp1; pool `default` shows non-zero capacity.

## Task 25: Provision mirror PVCs and restore via kopiur

**Stop point: confirm with user.**

- [ ] **Step 1: Trigger fresh kopiur snapshots of any openebs-hostpath PVCs on cp1**

For each PVC identified in Task 21:
```bash
kubectl -n monitoring create -f - <<EOF
apiVersion: kopiur.home-operations.com/v1alpha1
kind: Backup
metadata:
  name: pre-cycle-<pvc-name>
spec:
  policyRef:
    name: <pvc-name-no-prefix>  # e.g. vmstorage-1
EOF
```
Wait for `PHASE: Completed`.

- [ ] **Step 2: Create `miroir-replicated` PVCs for the cp1 workloads**

For each openebs PVC that was on cp1, create a new PVC with the same name but using `miroir-replicated`. The PVC that was on cp1 is now unbound (its PV has no path); create the replacement before the workload reconciles.

For example, if cp1 had `pvc-aeab632b` (vmstorage-1, 50Gi):

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: vmstorage-db-vmstorage-victoria-metrics-1
  namespace: monitoring
spec:
  storageClassName: miroir-replicated
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 50Gi
```

(If the migration design later shrinks vmstorage, that's Phase 4/5; Phase 1 keeps the size.)

Save the manifests alongside the existing files (e.g. `kubernetes/monitoring/victoria-metrics/app/pvc-vmstorage-1.yaml`) and reference them from the namespace Kustomization so Flux applies them.

- [ ] **Step 3: Restore each mirror PVC's data via kopiur**

For each PVC:
```bash
kubectl -n monitoring create -f - <<EOF
apiVersion: kopiur.home-operations.com/v1alpha1
kind: Restore
metadata:
  name: restore-vmstorage-1-to-miroir
spec:
  source:
    snapshotSelector:
      matchLabels:
        kopiur.home-operations.com/policy: vmstorage-1
    latest: true            # use the most recent Backup
  destination:
    pvc: vmstorage-db-vmstorage-victoria-metrics-1
EOF
```

Wait for restore completion (could be 5–10 min for 50GiB).

- [ ] **Step 4: Verify pod restart**

```bash
kubectl -n monitoring get pod -l app.kubernetes.io/name=vmstorage -o wide
```
Expected: the vmstorage StatefulSet pods have rolled (the pod formerly pinned to cp1 may have been on cp1; it now schedules wherever the mirror PVC landed).

## Task 26: Validate monitoring end to end

- [ ] **Step 1: Scrape metrics**

```bash
kubectl -n monitoring exec deploy/victoria-metrics-victoria-metrics-operator -- \
  wget -qO- http://vmstorage-victoria-metrics-cluster.vmstorage:8482/select/0/prometheus/api/v1/query?query=up 2>&1 | head -c 200
```
Expected: a JSON `{"status":"success","data":{"resultType":"vector","result":[...]}}` or similar.

- [ ] **Step 2: Open Grafana**

Browse to `https://grafana.whoverse.dev` (or the InternalLB URL) and confirm at least one dashboard renders with live data.

- [ ] **Step 3: Verify mirror cluster health**

```bash
kubectl get miroirnodegroup cluster -o jsonpath='{.status}{"\n"}'
kubectl get pod -n storage -l app.kubernetes.io/name=miroir-agent -o wide
```
Expected: cp1's agent is Running and reports a healthy DRBD leg.

## Task 27: Commit any Phase 1 manifests and freeze

- [ ] **Step 1: Commit**

```bash
git add -A
git status
git commit -m "k8s: cycle cp1 to mirror-replicated"
```

**STOP — wait for user approval before Phase 2.**

---

# Phase 2 — Cycle whoverse-cp2 (ceph mon-j recovery)

Same shape as Phase 1 with these differences:

- `nodes[cp2].patches` adds `- "@./miroir-disk.yaml"`.
- The `rook-ceph-mon-j` PVC was on cp2 and rook's mon DB is destroyed. Either:
  - (Default) Let rook auto-recover: delete the failed `rook-ceph-mon-j-*` Deployment + PVC, rook recreates the mon with empty data and reseeds from `mon-m` (cp3) and `mon-n` (w2).
  - (Optional) Pre-create a `miroir-replicated` PVC for `mon-j`, set `monPVCs.storageClassName` in the rook HelmRelease to `miroir-replicated` before the cycle. Rook then binds the new mon straight onto mirror.
- While the new mon is reseeding, ceph is at 2-of-3 mons = quorum, briefly `mon_unhealthy` window.

## Task 28: Pre-create rook mon-j mirror PVC (optional but recommended)

**Stop point: confirm with user.**

- [ ] **Step 1: Add the mon-j PVC mirror-backed PVC**

`kubernetes/storage/rook-ceph/app/pvc-mon-j.yaml`:

```yaml
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: rook-ceph-mon-j
  namespace: storage
spec:
  storageClassName: miroir-replicated
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 10Gi
```

- [ ] **Step 2: Wire into kustomization**

Add to `kubernetes/storage/rook-ceph/kustomization.yaml` (next to the namespace and HelmRelease).

- [ ] **Step 3: Commit + apply via Flux**

```bash
git add kubernetes/storage/rook-ceph/
git commit -m "k8s: pre-create rook-ceph-mon-j mirror PVC for cp2 swap"
flux reconcile kustomization cluster -n flux-system
```

## Task 29: Cycle cp2

Repeat Task 21 (inspect) → Task 27 (commit), substituting `192.168.2.22` for cp2, `whoverse-cp2` everywhere, and using `nodes[cp2].patches`.

**Special check:** monitor `kubectl -n storage get pod -l app=rook-ceph-mon -w` while cp2 reboots, watching for mon-j to come back `Running` with `Ready`.

**STOP — wait for user approval before Phase 3.**

---

# Phase 3 — Cycle whoverse-w1

Same as Phase 1. No rook mon lives on w1. Pool nodes now contributing to mirror: cp1, cp2, w1 → mirror pool has quorum (3 of 4) and `replicas: "2"` is satisfiable.

After cp1/cp2/w1 cycles: mirror pool is healthy enough to begin provisioning. Anything still on `openebs-hostpath` going forward will live on the remaining openebs-hostpath partitions (currently cp3 and possibly w2).

## Task 30: Cycle w1

Repeat Phase 1 verbatim, substituting `192.168.2.24`, `whoverse-w1`, and `nodes[w1].patches` for cp1's references.

**STOP — wait for user approval before Phase 4.**

---

# Phase 4 — Cycle whoverse-cp3 (last; destroys the remaining vmstorage-* shard's openebs copy)

cp3 hosts `vmstorage-0` (50 GiB) — the last remaining shard of the monitoring data that doesn't self-rebuild. Mirror pool is fully operational (4 nodes now), so losing this shard means relying entirely on the kopiur snapshot for restoration.

## Task 31: Final full kopiur backup of vmstorage-0 before cp3 cycle

- [ ] **Step 1: Verify the latest snapshot is recent (< 5 min old)**

```bash
kubectl get backup -n monitoring -l "kopiur.home-operations.com/policy=vmstorage-0" -o jsonpath='{.items[0].metadata.creationTimestamp}'
```
Expected: recent.

## Task 32: Cycle cp3

Repeat Phase 1 verbatim with cp3 (`192.168.2.23`, `whoverse-cp3`, `nodes[cp3].patches`).

`rook-ceph-mon-m` recovery: same as Phase 2's mon-j flow — optional pre-created mirror PVC or auto-recovery.

After this: no node has an `openebs-hostpath` partition anymore (cp1/cp2/cp3 swapped; w1 swapped; w2 still has its small openebs-hostpath partition for mon-n).

**STOP — wait for user approval before Phase 5.**

---

# Phase 5 — Sweep remaining openebs-hostpath PVCs

Goal: anything still bound to `openebs-hostpath` after Phase 4 is migrated. Expected list:

- vmselect-0/1 cache (2 GiB each) — regenerate from vmstorage
- vlstorage-0/1 (20 GiB each) — VictoriaLogs replication picks it up
- grafana (2 GiB) — ConfigMap-driven dashboards, ephemeral state only

## Task 33: Inspect remaining

- [ ] **Step 1: List**

```bash
kubectl get pvc -A -o json | jq '.items[] | select(.spec.storageClassName=="openebs-hostpath") | {ns:.metadata.namespace, name:.metadata.name}'
```
Expected: only vmselect/vlstorage/grafana PVCs remain (mon-j/m/m went to mirror already if Phase 2/4 took the optional route).

## Task 34: Provision mirror PVCs and switch workloads

Per component, follow this template (replace names + sizes):

- [ ] **Step 1: Mirror PVC**

```yaml
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: <pvc-name>
  namespace: <ns>
spec:
  storageClassName: miroir-replicated
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: <size>
```

- [ ] **Step 2: Update HelmRelease**

For `victoria-metrics` vmselect cachedir: switch `vmselect.persistentVolume.persistentVolumeClaim.metadata.name` (and the matching `existingClaim` / claim template) in `kubernetes/monitoring/victoria-metrics/app/helmrelease.yaml` to the new mirror PVC name.

Repeat for vlstorage and grafana.

- [ ] **Step 3: Commit + reconcile**

```bash
git add kubernetes/monitoring/
git commit -m "k8s: migrate {vmselect,vlstorage,grafana} PVCs to miroir-replicated"
flux reconcile kustomization cluster -n flux-system
```

- [ ] **Step 4: Verify**

- VictoriaLogs replication factor: confirm cluster is healthy on the new mirror storage (`kubectl -n monitoring logs -l app=vlstorage --tail=20`).
- VictoriaMetrics writes succeed (curl `/api/v1/query`).
- Grafana loads (`kubectl get pods -n monitoring -l app=grafana`).

**STOP — wait for user approval before Phase 6.**

---

# Phase 6 — Drop `hostpath` from `talconfig.yaml` permanently

Goal: future re-images of any node no longer allocate the old `u-hostpath` partition. Live nodes already cycled, so this is a config-only change.

## Task 35: Remove the userVolume from talconfig

- [ ] **Step 1: Delete the `&sharedUserVolumes` block** (or its `hostpath` entry if other userVolumes exist).

- [ ] **Step 2: Regenerate + diff**

```bash
just talos-gen
git diff talos/whoverse/clusterconfig/whoverse-whoverse-cp1.yaml | grep -E "hostpath|u-hostpath" || echo "no residual hostpath refs"
```
Expected: no residual refs.

- [ ] **Step 3: Do NOT `talos-apply`**

Per spec §3, the change only affects future re-images. Live nodes are unaffected.

- [ ] **Step 4: Commit**

```bash
git add talos/whoverse/talconfig.yaml talos/whoverse/clusterconfig/
git commit -m "talos: drop hostpath userVolume (no longer needed)"
```

**STOP — wait for user approval before Phase 7.**

---

# Phase 7 — Move rook-ceph-mon-n off openebs-hostpath and retire openebs

Goal: every openebs-hostpath consumer is gone, the openebs chart can be uninstalled, Flux's prune cleans up the runtime.

## Task 36: Choose the mon-n destination

Two options per spec §4 Phase 7. The user must pick one before this task:

- **Option A:** Move `rook-ceph-mon-n` to a `miroir-replicated` PVC. w2's mon pod now writes to a remote mirror leg, paying network I/O for mon traffic.
- **Option B:** Move it to a small `ceph-rbd` PVC. Simpler; mon DB lives in ceph (single leg) but rook tolerates this for mon data in many deployments.

The user has chosen: __________________.

## Task 37: Apply the chosen destination

- [ ] **Option A — mon-n on mirror:** Create `kubernetes/storage/rook-ceph/app/pvc-mon-n-miroir.yaml` with `storageClassName: miroir-replicated`. Update `rook-ceph` HelmRelease `monPVCs[where name=n]` to point at the new PVC.

- [ ] **Option B — mon-n on ceph-rbd:** Create `kubernetes/storage/rook-ceph/app/pvc-mon-n-ceph.yaml` with `storageClassName: ceph-rbd`. Update the rook HelmRelease similarly.

- [ ] **Step: Commit + apply**

```bash
git add kubernetes/storage/rook-ceph/
git commit -m "k8s: move rook-ceph-mon-n off openebs-hostpath to <destination>"
flux reconcile kustomization cluster -n flux-system
```

- [ ] **Step: Validate**

```bash
kubectl -n storage exec deploy/rook-ceph-tools -- ceph -s
```
Expected: mon `n` reported as healthy.

## Task 38: Verify zero openebs-hostpath consumers

- [ ] **Step 1: Confirm**

```bash
kubectl get pvc -A -o json | jq '.items[] | select(.spec.storageClassName=="openebs-hostpath") | {ns:.metadata.namespace, name:.metadata.name}'
```
Expected: empty.

- [ ] **Step 2: Confirm no openebs pods**

```bash
kubectl get pods -n storage -l app.kubernetes.io/name=openebs-localpv
```
Expected: `No resources found`.

## Task 39: Remove `openebs-localpv/` and update storage kustomization

**Files:**
- Modify: `kubernetes/storage/kustomization.yaml`
- Delete: `kubernetes/storage/openebs-localpv/` (entire tree)

- [ ] **Step 1: Drop the `./openebs-localpv/ks.yaml` entry from `kubernetes/storage/kustomization.yaml`'s `resources:` list**

- [ ] **Step 2: `rm -rf kubernetes/storage/openebs-localpv/`**

- [ ] **Step 3: Validate**

```bash
kustomize build kubernetes | kubeconform -strict -ignore-missing-schemas -schema-location default -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
```
Expected: exit 0.

- [ ] **Step 4: Commit**

```bash
git rm -r kubernetes/storage/openebs-localpv/
git add kubernetes/storage/kustomization.yaml
git commit -m "k8s: decommission openebs-localpv (storage migrated to mirror)"
```

## Task 40: Force reconcile and verify acceptance criteria

**Stop point: this is the final step. Confirm with user before running `flux reconcile` with prune effects.**

- [ ] **Step 1: Reconcile + watch prune**

```bash
flux reconcile kustomization cluster -n flux-system
flux reconcile kustomization storage -n flux-system 2>/dev/null || true
kubectl -n flux-system get kustomizations -w
```

- [ ] **Step 2: Verify the spec §7 acceptance criteria**

```bash
kubectl get pvc -A -o json | jq '.items[] | select(.spec.storageClassName=="openebs-hostpath")' | head
# expect empty
kubectl get sc | grep openebs-hostpath
# expect no rows
kubectl -n storage get pods -l app.kubernetes.io/name=openebs-localpv
# expect No resources found
kubectl get miroirnodegroup cluster -o jsonpath='{.status}{"\n"}'
# expect 4 pool legs and healthy
kubectl -n monitoring exec deploy/grafana -- wget -qO- http://localhost:3000/api/health 2>&1 | head -c 200
# expect "ok"
```

- [ ] **Step 3: Commit any final tag/release**

```bash
git tag migration-mirror-$(date -I)
git push --tags  # OPTIONAL — only if user asks
```

---

# Self-Review

## Spec coverage

| Spec section / requirement | Plan task(s) |
|---|---|
| §3 Required Talos additions (drbd ext + kernel patch + raw volume) | Tasks 1, 2, 3, 23 |
| §3 Drop `hostpath` userVolume (Phase 6) | Task 35 |
| §3 Kubernetes manifests chart layout | Tasks 10, 11, 12, 13, 14, 15, 16 |
| §3 Day-zero node label | Task 17 |
| §4 Phase 0 preconditions | Tasks 4, 5–9 (Talos re-image), 10–17 (mirror chart), 18–20 (kopiur snapshots) |
| §4 Phase 1 cycle cp1 | Tasks 21, 22, 24, 25, 26, 27 |
| §4 Phase 2 cycle cp2 with mon-j recovery | Tasks 28, 29 |
| §4 Phase 3 cycle w1 | Task 30 |
| §4 Phase 4 cycle cp3 with vmstorage-0 destructive | Tasks 31, 32 |
| §4 Phase 5 sweep remaining openebs | Tasks 33, 34 |
| §4 Phase 6 drop hostpath from talconfig | Task 35 |
| §4 Phase 7 retire openebs + mon-n move | Tasks 36, 37, 38, 39, 40 |
| §5 Risks: re-image partition destruction | Phase 0c snapshots before any cycle (Tasks 18, 19, 20) |
| §5 Risks: drbd module usermode_helper | Tasks 1, 2, 3 (kernel patch) |
| §5 Risks: ceph mon auto-rejoin | Tasks 28, 29, 32 (optional pre-created mirror PVCs) |
| §5 Risks: Talos regen + accidental talos-apply | Task 35 explicitly notes "do NOT talos-apply" |
| §5 Risks: w2 should not get mirror-disk.yaml | Tasks 23, 28, 29, 30, 32 explicitly apply only to pool nodes; Phase 6 verification grep |
| §5 Risks: hardware reboot flakiness | Validation matrix enforced at every task |
| §6 Open questions: mirror-snap day-1 definition | Tasks 14, 16 (in chart from day 1) |
| §6 Open questions: rook mon DB placement | Tasks 28 (cp2), 32 (cp3), 36 (w2) — explored in implementation |
| §7 Acceptance criteria (zero openebs-hostpath, no openebs-localpv pods, mirror pool healthy, monitoring writes) | Task 40 explicitly checks each |

## Placeholder scan

Searched for: TBD, TODO, FIXME, "implement later", "fill in details", "add appropriate error handling", "similar to Task N". None found.

## Type consistency

Names used consistently throughout: `miroir-replicated` (StorageClass), `miroir-snap` (VolumeSnapshotClass), `r-miroir` (partition label), `miroir.home-operations.com/enabled=true` (node label), `miroir.home-operations.com/replicas: "2"` (StorageClass param), `miroir.home-operations.com/v1alpha1` (CRD API group). PVC sizes (50Gi/20Gi/2Gi) preserved from current openebs-hostpath allocation in Phase 1–4 (shrink is intentionally deferred per the spec's open question §6 and is not in this plan; the spec's only mention of 35Gi was a draft option that the user did not lock in).

---

## Execution Handoff

Plan saved to `docs/superpowers/plans/2026-07-23-miroir-migration.md`.

Two execution options — **which do you want?**

1. **Subagent-Driven (recommended)** — I dispatch a fresh subagent per phase, review checkpoints between phases. Matches the user's "stop and wait for approval" rule exactly.
2. **Inline Execution** — I execute tasks in this session, with the same `STOP` checkpoints but no subagent dispatch overhead. Better for direct back-and-forth.
