# Replace `openebs-hostpath` with `miroir` (DRBD-replicated LVM-thin) on the three control-plane nodes

- **Date:** 2026-07-23
- **Status:** Draft, pending user review
- **Owner:** home-ops maintainers

## 1. Problem

The monitoring stack (Grafana, VictoriaLogs, VictoriaMetrics,
VictoriaLogs/VictoriaMetrics `vmselect` cache) and the three `rook-ceph-mon-*`
PVCs currently sit on the `openebs-hostpath` storage class. OpenEBS
`localpv-hostpath` is implemented as a node-local `hostPath` mount under
`/var/mnt/hostpath` on every node, so each PVC is pinned to whichever node its
PVC directory happens to live on. There is no replication, no automatic
failover, no CSI snapshot support, and the controller layout (a
`DaemonSet` of `openebs-localpv-alloy` pods on every node plus a single
provisioner) is heavier than the workload it serves. The partition that backs
`/var/mnt/hostpath` is carved out of each node's system disk by a Talos
`UserVolumeConfig` named `hostpath` (label `u-hostpath`).

The `home-operations/miroir` project is a CSI driver for small Kubernetes
clusters that provisions DRBD-replicated LVM-thin (or ZFS, or loopfile) block
storage. With DRBD9 mirroring, every PVC is replicated across nodes and
survives a one-node failure. The `drbd` module shipped by Talos ≥ 1.13.0 is a
drop-in replacement for the openebs use case, eliminates the
`openebs-localpv-alloy` `DaemonSet`, and unlocks standard CSI features
(snapshots, expansion, group snapshots) for free.

## 2. Goal

Replace every use of the `openebs-hostpath` storage class with a
`miroir-replicated` storage class backed by DRBD-replicated LVM-thin. The
`openebs-localpv` controller is decommissioned. Ceph-rbd, kopiur, volsync, and
all other storage classes stay untouched.

### In scope

- The 12 PVCs that currently bind to `openebs-hostpath` (monitoring + 3 rook
  mons).
- The Talos configuration that allocates the underlying disk partitions:
  `talos/whoverse/talconfig.yaml`, the `hostpath` `UserVolumeConfig`, and the
  `ceph-osd-volume.yaml` peer pattern.
- The `kubernetes/storage/openebs-localpv/` Flux Kustomization and
  HelmRelease.

### Out of scope

- Rook-Ceph OSD migration. OSDs on `/dev/sdb1` (`r-rook-osd`) are untouched
  for the whole migration.
- Ceph-rbd (`storageclass.kubernetes.io/is-default-class=true`) and any of the
  ~22 PVCs that already use it.
- Volsync, kopiur repo `whoverse`, and the 14 already-backed-up apps
  (`prowlarr`, `sonarr-*`, `radarr-*`, `jellyfin`, `seafile-*`, etc.).
- DRBD `replicas` upgrade beyond `"2"` with automatic diskless tie-breaker.
- Mirror monitoring stack (so far, mirror is treated as a black-box block
  driver).

## 3. Target state

### Storage pool

| Concern | Value |
|---|---|
| Backend | LVM-thin (`lvmthin`) |
| Per-node device | `/dev/disk/by-partlabel/r-miroir` |
| Per-node partition size | `minSize: 128GiB` / `maxSize: 128GiB` (carved from `system_disk`) |
| Pool nodes | `whoverse-cp1`, `whoverse-cp2`, `whoverse-cp3`, `whoverse-w1` |
| Replication | DRBD9, `replicas: "2"` + automatic diskless tie-breaker on the 4th node |
| Pool resource shape | one `MiroirNodeGroup` with a node-label selector |
| StorageClass name | `miroir-replicated` |
| VolumeSnapshotClass name | `miroir-snap` (defined but unused — see §6) |

### Per-node disk math (each storage node keeps `EPHEMERAL` unchanged)

| Node | system_disk | r-miroir max | EPHEMERAL | EFI/META/STATE | free after |
|---|---|---|---|---|---|
| cp1 | sda 256 GB | 128 GB | 64 GB | ~2.5 GB | ~62 GB |
| cp2 | sda 256 GB | 128 GB | 64 GB | ~2.5 GB | ~62 GB |
| cp3 | sda 256 GB | 128 GB | 64 GB | ~2.5 GB | ~62 GB |
| w1 | sda 1 TB | 128 GB | 64 GB | ~2.5 GB | ~830 GB |

`w2` (libvirt VM, sda 137 GB) deliberately stays out of the pool to preserve
its small disk for general use. Pool total: **512 GB raw / ~256 GB usable**
with `replicas: "2"`. The 12 migrating PVCs request ≈196 GiB of usable
storage, leaving ~60 GB headroom.

### Required Talos additions

- `controlPlane.schematic.customization.systemExtensions.officialExtensions`:
  add `siderolabs/drbd` (already required for replication). DRBD9 ≥ 9.3.1 is
  shipped by Talos ≥ 1.13.0, and the cluster is on 1.13.5.
- `worker.schematic.customization.systemExtensions.officialExtensions`: also
  add `siderolabs/drbd` — `w1` is a worker and is in the pool.
- New `talos/whoverse/patches/miroir-kernel.yaml` (referenced from both
  `controlPlane.patches` and `worker.patches`):

  ```yaml
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

  The `usermode_helper=disabled` parameter is mandatory: the Talos `drbd`
  module's kernel side calls `/sbin/drbdadm`, which does not exist on Talos.
  The kubelet graceful-shutdown timings are required so the mirror agent
  (a `system-node-critical` pod) stops *after* workloads on reboot and can
  release DRBD backings before the backend pool exports.

- New `talos/whoverse/miroir-disk.yaml` (peer of `ceph-osd-volume.yaml`),
  referenced from each pool node's `nodes[].patches`:

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

  Apply via `nodes[cp1].patches`, `nodes[cp2].patches`, `nodes[cp3].patches`,
  and `nodes[w1].patches`. **Do not** apply to `w2`.

- Drop the existing `hostpath` `UserVolumeConfig` from the
  `&sharedUserVolumes` YAML anchor in `talconfig.yaml`. The label `u-hostpath`
  disappears from every node on the next `talos-gen`/`talos-apply`.

The Talos label caveat ("Ceph will not create a partition if the partition
label contains the substring `ceph`") does not apply — the new label
`r-miroir` is clean.

### Kubernetes manifests

New directory: `kubernetes/storage/miroir/`.

```text
kubernetes/storage/miroir/
├── ns.yaml
├── ks.yaml
├── kustomization.yaml
└── app/
    ├── helmrelease.yaml
    ├── miroirnodegroup.yaml
    ├── storageclass.yaml
    └── volumesnapshotclass.yaml
```

`MiroirNodeGroup`:

```yaml
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

Day-zero node-label step (manual, run once after `ns.yaml`/`HelmRelease` are
applied):

```bash
kubectl label node whoverse-cp1 whoverse-cp2 whoverse-cp3 whoverse-w1 \
  miroir.home-operations.com/enabled=true
```

`StorageClass` `miroir-replicated`:

```yaml
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

### Helm chart

Chart: `oci://ghcr.io/home-operations/charts/miroir`, installed in the
existing `storage` namespace (already created by `storage/kustomization.yaml`).

### Existing assets reused

- `kubernetes/storage/kustomization.yaml` gets one new entry:
  `./miroir/ks.yaml`.
- `kubernetes/storage/miroir/app/helmrelease.yaml` references an OCI Helm
  repository that is added to `kubernetes/flux-config/registry/helm/`.
- Cookie-cutter follows the same shape as the existing
  `kubernetes/storage/openebs-localpv/` directory.

## 4. Migration phases

Each phase ends with: a kubeconform validation pass, a `git commit` of any
manifest additions, and a status check (`flux-status`, `kubectl get
miroirnode/-group`, `talosctl get volumestatus`).

The phase ordering keeps the cluster in a working state throughout:

- Ceph quorum holds at all times (3 mons, never more than 1 absent).
- Openebs-hostpath remains alive until the last phase.
- The Talos kernel-module + shutdown-grace changes are applied *before* the
  disk swap, so the kernel side of DRBD is verified before LVM volumes show up.
- The mirror chart is installed on day zero with `r-miroir` partitions
  missing; the agent will sit idle on each storage node until the partition
  appears.

### Phase 0 — preconditions (no downtime)

1. Apply the new `talconfig.yaml` changes that **only** affect the Talos
   schematic (the `siderolabs/drbd` extension in both `controlPlane` and
   `worker` blocks) plus `patches/miroir-kernel.yaml`. Do this as a separate
   `just talos-gen && just talos-apply` cycle per node. Partition layout is
   unchanged — only the kernel modules and shutdown-grace config land. Validate
   on every node:

   ```bash
   talosctl -n <cp> read /proc/modules | grep drbd
   talosctl -n <cp> get kubeletconfig | grep -E "shutdownGracePeriod"
   ```

2. Apply the `kubernetes/storage/miroir/` chart with `r-miroir` partitions
   absent. The agent stays in `DeviceNotFound` until the partitions show up;
   the controller is up and the `StorageClass` is usable.

3. Add `SnapshotPolicy` + `SnapshotSchedule` for the three `vmstorage-*`
   PVCs only, using the existing `whoverse` ClusterRepository. Wait one
   snapshot cycle (~1 hour) so each vmstorage shard has at least one
   restorable snapshot before any Talos partition swap.

### Phase 1 — cycle `cp1`

1. `kubectl drain whoverse-cp1 --ignore-daemonsets`.
2. `kubectl create -f Backup.yaml` per openebs-hostpath PVC on cp1 (or wait
   for the next hourly snapshot).
3. `just talos-apply -n 192.168.2.21` with the new `miroir-disk.yaml` patch.
   The `u-hostpath` partition is replaced by `r-miroir`; node reboots.
4. Validate: `talosctl -n 192.168.2.21 get volumestatus r-miroir` →
   `ready`. `talosctl -n 192.168.2.21 list /var/mnt/hostpath` is now empty
   (partition gone).
5. Create mirror PVCs for whichever vmstorage/vlstorage/vmselect/grafana
   shards landed on cp1. `Restore` against each mirror PVC via kopiur. Move
   the workload over by changing the HelmRelease values for that component
   to the new `mirror-replicated` storage class and storage size.
6. Validate: monitoring dashboards render, metrics write succeeds.

### Phase 2 — cycle `cp2`

Same as Phase 1, plus:

- The `rook-ceph-mon-j` PVC was on cp2. After cp2 cycles, that PVC's
  underlying path is gone and the mon pod will fail. Rook redeploys the mon
  on its PVC-less state with empty data; surviving `mon-m` (cp3) and
  `mon-n` (w2) maintain quorum and reseed `mon-j`. Optionally create the
  mon-j PVC on `mirror-replicated` ahead of the cycle so rook has somewhere
  to land; otherwise let rook use the same PVC name once the openebs PV is
  released.

### Phase 3 — cycle `w1`

Same as Phase 1. No ceph mon on w1 today (the `hostpath` volume on w1 only
held `vmselect-0`, `vmstorage-2`, `vlstorage-0`). After w1 is in the pool,
`mirror` has quorum: 3 of 4 nodes contributing to DRBD. Replicas can be
provisioned.

### Phase 4 — cycle `cp3` (last)

This is the one that kills `vmstorage-0` (the only irrecoverable shard). The
mirror pool is already live and serving at this point, so the temporary
victoria-metrics/victoria-logs outage is bounded to the time it takes rook
(or kopiur-restore) to repopulate. Ceph `mon-m` self-rebuilds the same way
`mon-j` did.

### Phase 5 — sweep remaining openebs-hostpath PVCs

Anything still on `openebs-hostpath` after the four cycles is either
rebuilt on mirror already, or (in the case of `rook-ceph-mon-n` on w2) is
still legitimately pinned to w2's system disk. Migrate anything that didn't
move with its home cycle, using the same per-component restore pattern.
Unbind and delete openebs PVCs once each workload has its mirror PVC
populated and a HelmRelease reconciliation shows the new mount in use.

### Phase 6 — drop `hostpath` from `talconfig.yaml` permanently

Remove `hostpath` from the YAML anchor block. `just talos-gen`. No
`talos-apply` is needed on live nodes — the change only affects future
re-images. The `OpenEBS` storage class still exists in the cluster but has
no consumers.

### Phase 7 — retire openebs

1. Move `rook-ceph-mon-n` (w2) off openebs-hostpath. Two options:
   - Re-schedule it onto a `mirror-replicated` PVC and accept that w2's pod
     writes to a remote mirror leg; or
   - Provision a small `ceph-rbd` PVC for it (rook docs generally recommend
     host-local for mons, but w2's openebs pool is small enough that this
     is acceptable trade-off).
2. Once no PVC references `openebs-hostpath`, delete the `StorageClass` and
   the `kubernetes/storage/openebs-localpv/` Flux Kustomization. Update
   `kubernetes/storage/kustomization.yaml` to remove the `openebs-localpv/ks.yaml`
   reference. Validate. Commit.

### Phase 8 — decommission `openebs-localpv` runtime

Remove the `openebs-localpv-alloy` DaemonSet, `openebs-localpv-localpv-provisioner`,
the Helm release, and the related RBAC. Easiest path: delete the entire
`kubernetes/storage/openebs-localpv/` tree and let Flux's prune (currently
`prune: true` on the cluster root) clean up the runtime. Validate everything
else still works.

## 5. Risks and mitigations

| Risk | Mitigation |
|---|---|
| Re-imaging Talos with a new partition layout destroys the `u-hostpath` partition and therefore every PVC whose data is on that node. | Phase 0 snapshots the only non-rebuilding data (`vmstorage-*`) before any partition swap. The four cycles happen one node at a time. The openebs PVCs are always recoverable by re-creating them empty or by kopiur-restore. |
| DRBD module fails to load on a freshly re-imaged node (kernel side calls `/sbin/drbdadm` which doesn't exist). | The kernel-module patch sets `usermode_helper=disabled`. We re-image once with the patch *before* introducing `r-miroir`, and verify `/proc/modules` shows `drbd` on every node before Phase 1. |
| Ceph mon on a cycled node can't auto-rejoin because its PVC is gone. | Rook treats a missing mon DB the same as a fresh mon member — surviving mons reseed it. We accept the brief `mon_unhealthy` window. We optionally pre-provision a mirror PVC for mon-j/mon-m so the rook state can attach on first start. |
| Mirror chart starts agents that fail to find their device and emit errors, which pollutes logs. | Acceptable — the agent's `DeviceNotFound` is the expected pre-phase-1 state. Operators view `/var/log/pods/miroir-agent-*` for confirmation rather than treating absence-of-errors as a health signal. |
| `diskSelector.match: system_disk` doesn't behave the way it does for `!system_disk`. | Tested locally with `talosctl get volumestatus` after Phase 0a on a single node before rolling. If the selector is ambiguous, fallback is `diskSelector.match: install_disk` or a path-based selector (`/dev/disk/by-id/wwn-0x...`) per node, with one `miroir-disk.yaml` per node replacing the shared file. |
| Auto diskless tie-breaker costs capacity — usable storage halves on a 4-node pool when one node is down. | Acceptable: with `replicas: "2"` and 4 nodes contributing, the pool can lose 1 node without losing access to any PVC. The auto-diskless tie-breaker means the 3rd replica (a witness) costs no disk. |
| `just talos-gen` regenerates the 5-node configs including the dropped userVolume change; an accidental `talos-apply` against the wrong node wipes its `u-hostpath` without `r-miroir` as a replacement. | Phase order ensures `r-miroir` is declared *before* `hostpath` is removed in `talconfig.yaml` for any node we cycle. Verify with `git diff` before each apply. |
| A copy of `miroir-disk.yaml` ends up applied to `w2` (the small VM). | Per-node patches: each `nodes[i].patches` lists explicitly. The shared `worker.patches:` is only used for files that should land on both w1 and w2 (i.e. the kernel module patch). The raw-volume patch is per-node. |
| Several Talos reboot cycles in a row raise the chance of node-side hardware hiccups (ZimaBoards are known-flaky). | Cycles are scheduled manually with a maintenance window. Each reboot validates `talosctl health -n <ip>` before moving on. |

## 6. Open questions

- **`mirror-snap` VolumeSnapshotClass.** Mirror's CSI driver may or may not
  expose `VolumeSnapshot` support in the chart version available at install
  time. Define the class anyway and verify it during Phase 0b; if not
  supported yet, leave the class out and rely on kopiur for restore.
- **Rook mon DB placement.** Some rook versions complain when mon DB is on
  shared replicated storage because the device path changes under failover.
  Validate during Phase 2 that rook is happy with `mirror-replicated` mons
  before committing to it for cp3 as well. If not, fall back to rook's
  built-in mon recovery against empty data (slow, but works).

## 7. Validation

Local-equivalent of CI:

```bash
kustomize build kubernetes/storage/miroir | kubeconform -strict \
  -ignore-missing-schemas -schema-location default \
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
```

Cluster-side checks after each phase:

```bash
just flux-status
kubectl get miroirnodegroup cluster -o jsonpath='{.status}'
kubectl get pvc -A -o json | jq '.items[] | {ns:.metadata.namespace,name:.metadata.name,sc:.spec.storageClassName}'
talosctl get volumestatus r-miroir -n <node>
```

Acceptance criteria for completion of Phase 8:

- `kubectl get pvc -A` shows zero PVCs with `storageClassName: openebs-hostpath`.
- `kubectl get sc` does not show `openebs-hostpath`.
- `kubectl get pods -n storage -l app.kubernetes.io/name=openebs-localpv` is
  empty.
- `kubectl exec -n storage deploy/miroir-controller -- miroir pool status`
  (or equivalent) reports 4 pool legs and a healthy DRBD quorum.
- Monitoring dashboards render and metrics writes succeed end-to-end
  (sample-write then sample-query).
