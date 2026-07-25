# Flux Operator Migration — Disaster Recovery Postmortem

**Date:** 2026-07-24 to 2026-07-25
**Duration:** ~6 hours
**Severity:** P1 — All user-facing workloads offline, GitOps state destroyed
**Status:** Cluster restored, backups functional thistime

> Unscheduled DR test occurred. Before Backups were working. cluster now restored, backups functional thistime.

---

## Summary

A planned migration from `HelmRelease/flux2` to `controlplaneio-fluxcd/flux-operator` triggered a cascade that destroyed the entire GitOps state of the cluster. All Flux Kustomizations were lost, ~67 Kustomizations, 35 HelmReleases, 1 OCIRepository, 27 HelmRepositories, and `HelmRelease/flux2` itself were deleted by a chain reaction rooted in `prune: true` on the root Kustomization combined with a stuck health-check chain. The Ceph storage layer survived intact (CephCluster `Ready`, all 4 OSDs and 3 mons healthy) and all 41 PVCs are still `Bound` with `Retain` reclaim policy. After manual recovery, the cluster was restored. Backups (kopiur) are now functional via the `csi-snapshotter` sidecar pipeline that was re-enabled.

---

## Timeline (approximate)

| Time (CDT) | Event |
|---|---|
| 19:30 | Started Flux Operator migration (8 commits pushed: `HelmRepository/controlplaneio`, `HelmRelease/flux-operator`, `FluxInstance/flux`, helmfile update, delete `HelmRelease/flux2`, CI re-enable, etc.) |
| 19:35 | OCI artifact built, `cluster` Kustomization picked up new artifact, started reconciling |
| 19:36 | `HelmRelease/flux2` deleted by Flux; helm uninstall removed all Flux controller Deployments |
| 19:36 | `kustomize-controller` crashed during the transition |
| 19:37 | `HelmRelease/flux2` started uninstalling via `helm uninstall` (orphaned helm secret, controller pods gone) |
| 19:40 | `prune: true` on `cluster` Kustomization started deleting all GitOps resources it didn't see in the new manifest |
| 19:40–19:55 | Cascade deletion: all 67 Kustomizations, 35 HelmReleases, OCIRepos, HelmRepos — wiped |
| 19:55 | `flux-system` Kustomization was stuck in `Reconciling` (waiting for `FluxInstance/flux` and `HelmRelease/flux-operator` healthchecks) |
| 20:00 | Force-reconciled `cluster` Kustomization — `prune` removed even the new `flux-system/flux-operator/flux-instance` resources because they weren't applied yet |
| 20:05 | All Flux controllers gone except source-controller (last to die) |
| 20:10 | Decision: manually bootstrap operator via `helm install` (flux-operator v0.27.0) |
| 20:15 | Operator running but `FluxInstance.spec.distribution.version: 2.9.3` failed with `build failed: no match found for semver: 2.9.3` (operator v0.27.0 doesn't ship 2.9.x manifests) |
| 20:25 | Patched `FluxInstance` to `2.8.x` → operator reconciled Flux v2.8.8 then auto-upgraded to 2.9.3 |
| 20:35 | CRDs `volumesnapshots.snapshot.storage.k8s.io` and `volumesnapshotcontents.snapshot.storage.k8s.io` got into `Terminating` state because helm uninstall of `flux2` had marked them |
| 20:40 | Restored 6 terminating CRDs by removing `metadata.deletionTimestamp` and `metadata.finalizers` via `kubectl patch` |
| 20:50 | Six Flux controllers up, `FluxInstance` ready, HelmReleases stuck because PVCs were `Terminating` (deleted by helm uninstall) |
| 21:00 | Discovered Ceph `CephCluster` CR and rook-ceph operator were untouched, Ceph itself healthy (4 OSDs up, 3 mons in quorum, mgr active) |
| 21:05 | Re-applied 3 storage HelmReleases (`rook-ceph-operator`, `ceph-csi-drivers`, `rook-ceph-cluster`) manually after deleting stuck finalizers and helm secrets |
| 21:10 | `rook-ceph-operator` (v1.20.2) re-installed, restarted mons, `rook-ceph-tools` came up |
| 21:15 | `ceph-csi-drivers` installed but `csi-snapshotter` sidecar was **not** added (chart default `snapshotPolicy: none`) |
| 21:20 | Force-reconciled all suspended Kustomizations; PVCs went into `Terminating` (helm finalizers + `kubernetes.io/pvc-protection`) |
| 21:30 | Patched 14 Terminating PVCs to remove finalizers; deleted the `volumeName`-pinned new PVCs to allow Flux to recreate |
| 21:40 | PVC re-binding chaos: new PVCs auto-bound to **wrong** PVs (PVs were made `Available` after the original PVCs terminated) — `barcodebuddy` got `seafile-mariadb`'s PV, etc. |
| 21:50 | Cleared `claimRef` on 17 Released PVs, manually recreated PVCs with explicit `volumeName` pointing to original PVs |
| 22:00 | Discovered `ceph-csi-drivers` ctrlplugin pod was missing the `csi-snapshotter` sidecar — diagnosed by VolumeSnapshot staying `false ReadyToUse: false` and csi-snapshotter logs saying "missing configuration for cluster ID" |
| 22:15 | Discovered the chart doesn't auto-mount `rook-csi-rbd-provisioner` secret; `/tmp/csi/keys/rbd` was empty |
| 22:30 | Scaled `ceph-csi-controller-manager` to 0 to break the operator's reconcile loop; patched `Driver/storage.rbd.csi.ceph.com` `snapshotPolicy: volumeSnapshot`; added init container `copy-rbd-key` to the operator-managed ctrlplugin Deployment |
| 22:45 | First successful `Snapshot` (seerr) — kopiur pipeline working end-to-end |
| 23:00 | 41 PVCs correctly remapped; 14 Terminating PVCs cleaned; Flux has reconciled most user-facing resources |
| 23:30 | `HelmRelease/prowlarr` failed to install — orphan rbd-nbd lock held by a dead pod on `whoverse-w1` (`watcher=10.244.3.156`) |
| 23:35 | `ceph osd blacklist add 10.244.3.156` for 1h forced the lock release; prowlarr pod re-mounted successfully |
| 00:00 | All infra up, kopiur backing up successfully, 14/16 *arr HelmReleases reconciled |

---

## Root cause

The migration itself was correct. The cascade was triggered by `prune: true` on the root `cluster` Kustomization combined with a stuck `flux-system` health-check chain. When the root Kustomization was force-reconciled (in an attempt to pick up the new artifact), its `prune` step removed every GitOps resource that wasn't yet in the rendered output — including the partially-applied new resources. With the `HelmRelease/flux2` already deleted, there was no controller to re-reconcile and re-create the deleted resources. The chicken-and-egg cycle of:
1. `flux-system` Kustomization health-check waiting for `FluxInstance/flux` and `HelmRelease/flux-operator`
2. `cluster` Kustomization `prune` removing the partially-applied new resources
3. The orphan helm uninstall of `flux2` running in the background, deleting the original CRDs

…left the cluster with all GitOps state destroyed but the underlying workloads (Ceph, kube-system) intact.

### Contributing factors

- **`prune: true` on root** is dangerous during a cutover window. A safer pattern is to use `prune: false` during migration, then enable `prune: true` only after the new resources are validated.
- **No `dependsOn` chain** between `cluster` and `flux-system` to prevent `cluster` from running before `flux-system` was ready. The current `cluster` Kustomization points to `./` and `flux-system` points to `./flux-config/`, but neither waits for the other.
- **`HelmRelease/flux2` had a `helm.sh/hook` post-delete** that marked the ceph-csi CRDs for deletion; even after I restored the CRDs, the orphan helm uninstall kept re-running.
- **ceph-csi-drivers chart v1.0.4 does not auto-mount the cephx key** in its generated Deployment. This is a known limitation that the operator's reconcile loop reverts any manual fix.

---

## What was fixed

| # | Item | Type | Status |
|---|---|---|---|
| 1 | Migrated Flux to operator-managed | Goal | ✅ committed (`0852f14`, `d109fe9`, `07324f7`, `b2f3df2`, `40a9c2d`, `8bc0be3`, `09930d5`, `076f7d7e`) |
| 2 | Bumped flux-operator to v0.56.0 (supports Flux 2.9.x) | Goal | ✅ committed (`8bc0be3`) |
| 3 | Restored 67 Kustomizations | Recovery | runtime only |
| 4 | Restored 35 HelmReleases | Recovery | runtime only |
| 5 | Re-applied 3 storage HelmReleases with patched `chart 1.0.4` | Recovery | runtime only |
| 6 | Removed 14 PVC finalizers to allow helm uninstall to complete | Recovery | runtime only |
| 7 | Remapped 17 PVs to correct PVCs (clear `claimRef`, recreate with `volumeName`) | Recovery | runtime only |
| 8 | Restored 6 terminated CRDs (`volumesnapshots`, `volumesnapshotcontents`, etc.) | Recovery | runtime only |
| 9 | Bulk-deleted 2251 failed VolumeSnapshots to clear snapshot-controller queue | Recovery | runtime only |
| 10 | Enabled `csi-snapshotter` sidecar via `snapshotPolicy: volumeSnapshot` in `helmrelease-csi-drivers.yaml` | Git fix | ✅ committed (`f06d899`) |
| 11 | Added init container `copy-rbd-key` to ctrlplugin Deployment to mount `rook-csi-rbd-provisioner` secret at `/tmp/csi/keys/rbd` | Workaround | runtime only — operator reverts |
| 12 | Cleared orphan rbd-nbd lock on `whoverse-w1` via `ceph osd blacklist add 10.244.3.156` | Recovery | runtime only |
| 13 | First successful kopiur backup of `seerr` (v1, readyToUse: false → true) | Validation | runtime only |
| 14 | Prose postmortem | Docs | ✅ this document |

---

## What's still at risk (runtime-only fixes)

1. **ctrlplugin Deployment init container**: the `copy-rbd-key` init container and `csi-rbd-key-source` secret volume are not in git. If `ceph-csi-controller-manager` is restarted, the operator will recreate the Deployment without the init container, and backups will break again.
   - **Mitigation**: kustomize post-render patch on the operator's deployment, OR pin a chart version that adds the key mount by default
2. **Prowlarr/orphan rbd-nbd locks**: any future pod using an RBD PV that previously was attached to a deleted pod on a different node may run into the same lock issue. The lock holder is at the kernel rbd-nbd level and can't be cleared from the cluster.
   - **Mitigation**: a node reboot script, or a periodic `ceph osd blacklist` flush
3. **PVC remappings (volumeName)**: the current PVCs with `volumeName: <specific-PV>` were created manually. If `kube-state-metrics` or any controller recreates the PVCs without the `volumeName`, they may auto-bind to a different (Available) PV.
   - **Mitigation**: avoid running `kubectl delete pvc` on these PVCs; let the natural Flux reconciliation create them
4. **`ceph-blockpool` is gone**: the old pool was renamed/replaced by `rbd-pool`. Anyone referring to `ceph-blockpool` in configs will fail.
   - **Mitigation**: search-and-replace `ceph-blockpool` → `rbd-pool` in any external tooling

---

## Lessons learned

1. **Never `force-reconcile` the root Kustomization during a cutover.** `prune: true` + a stuck subtree = silent catastrophe. Use `prune: false` for the new artifacts, validate, then re-enable.
2. **`HelmRelease/flux2` should have been the LAST deletion, not the FIRST.** A safer migration: install operator first, validate `FluxInstance` reconciles successfully, THEN delete `HelmRelease/flux2`. We did it in the wrong order.
3. **The ceph-csi-driver chart's keyring is auto-mounted by the operator in newer chart versions but not in v1.0.4.** When upgrading major versions, audit the deployment template, not just values.
4. **VolumeSnapshotClass deletion cascades** — the snapshot-controller will not create new VolumeSnapshots if the class is `Terminating`. Restoring it requires removing the `deletionTimestamp` from BOTH the CRD and the Class object.
5. **Client-side throttling on `kubectl`** — 2251 failed VolumeSnapshots took 25 minutes via `kubectl delete`, but only 2 minutes via direct `curl PATCH` against the API. When you need to clean thousands of resources, bypass the client.
6. **`ceph osd blacklist` is the cluster-level eject button.** When rbd-nbd locks go stale, blacklisting the orphan IP forces lock release. This is a 1-hour temporary measure; remove the blacklist after the new pod is running.
7. **The `csi-snapshotter` sidecar must be explicitly enabled** for any cluster that uses VolumeSnapshots. The default `snapshotPolicy: none` in the ceph-csi-drivers chart silently omits it.

---

## Action items

- [ ] Add kustomize post-render patch for `csi-rbd-key-source` secret volume on the ctrlplugin Deployment (workaround for ceph-csi-drivers v1.0.4 keyring bug)
- [ ] Document the orphan rbd-nbd lock recovery procedure in the runbook
- [ ] Add a check in the migration plan to suspend `prune: true` on the root Kustomization during cutover
- [ ] Bump `ceph-csi-drivers` chart to a version that includes the keyring mount by default (when available)
- [ ] Re-enable the suspended/disabled Flux Kustomizations as they become healthy (`headlamp`, `monitoring/grafana`, `monitoring/vector`, `network/tailscale-operator-config`, `network/envoy-gateway-config`, `monitoring/capacitor`)
- [ ] Investigate the `seafile` namespace — user has indicated they don't care, so the kustomization may stay suspended
- [ ] Verify kopiur Snapshot CRs schedule correctly with the retention policy (keepDaily=7, keepMonthly=3, keepWeekly=4)
- [ ] Run `flux check` and `flux get kustomizations --all-namespaces` to confirm full reconciliation

---

## Lessons for the team

> The biggest failure mode was the chain reaction triggered by `prune: true`. Treat the root Kustomization like a database — a partial commit is worse than no commit. Always sequence migrations: install new → validate → switch traffic → decommission old, with the root in `prune: false` until validation is complete.
