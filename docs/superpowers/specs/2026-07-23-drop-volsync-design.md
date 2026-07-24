# Drop VolSync — Design

**Date:** 2026-07-23
**Status:** Approved — ready for implementation plan
**Owner:** home-ops
**Companion plan:** `docs/superpowers/plans/2026-07-22-flatten-k8s-hierarchy.md` (Phase 7 task 7.1 must be edited, not executed)

---

## 1. Context

VolSync was previously the primary backup engine for ceph-rbd PVCs in `home-ops`. A single Kyverno `ClusterPolicy/volsync-backup` auto-generated one `ReplicationSource/<pvc>-backup` per ceph-rbd PVC, using the `kopia` mover to push snapshots to a Backblaze B2 bucket.

Kopiur (`kopiur.home-operations.com/v1alpha1`) has since been adopted and already backs up 14 of the 16 ceph-rbd PVCs. The only VolSync-only PVC is `default/memos`, which is unused and therefore not worth migrating.

This change removes VolSync (Helm chart, Kyverno generator, RBAC, repository, docs) in one PR, relying on Flux's prune to clean up cluster state. No replacement is added.

## 2. Goals

- Delete every VolSync manifest in the repository.
- Use Flux pruning to delete the corresponding cluster resources (HelmRelease, generated Kyverno objects, RBAC, HelmRepository).
- Leave every other backup path (Kopiur, Rook-Ceph, OpenEBS) untouched.
- Keep the repo buildable: `kustomize build` + `kubeconform` pass with no VolSync references.

## 3. Non-goals

- Renaming the 1Password item `volsync-kopia-password` (also used by Kopiur). Separate cleanup.
- Deleting the Backblaze B2 bucket `s3://whoverse-k8s-backups/volsync/*`. Out of scope.
- Adding a Kopiur backup component for `default/memos`. The app is unused.
- Restoring VolSync in the future if Kopiur proves insufficient. Reintroduction is its own spec.

## 4. Current State (what exists today)

| Path | Type | Notes |
|---|---|---|
| `kubernetes/storage/volsync/ks.yaml` | Flux `Kustomization` | `prune: false`, `wait: true`, depends on `rook-ceph` |
| `kubernetes/storage/volsync/app/kustomization.yaml` | K8s `Kustomization` | Lists `helmrelease.yaml` only |
| `kubernetes/storage/volsync/app/helmrelease.yaml` | `HelmRelease/volsync` | Chart `volsync` 0.18.5 from `perfectra1n/volsync` fork |
| `kubernetes/flux-config/registry/helm/volsync.yaml` | `HelmRepository/volsync` | URL `https://perfectra1n.github.io/volsync/charts/`, interval 24h |
| `kubernetes/storage/kustomization.yaml` | K8s `Kustomization` | Includes `volsync/ks.yaml` at line 7 |
| `kubernetes/flux-config/registry/helm/kustomization.yaml` | K8s `Kustomization` | Lists `volsync.yaml` at line 23 |
| `kubernetes/kyverno/policies/volsync-backup.yaml` | `ClusterPolicy/volsync-backup` | Generates `ExternalSecret` + `ReplicationSource` per ceph-rbd PVC |
| `kubernetes/kyverno/policies/kustomization.yaml` | K8s `Kustomization` | Lists `volsync-backup.yaml` (becomes empty after removal) |
| `kubernetes/kyverno/rbac/rbac.yaml` | `ClusterRole` + `ClusterRoleBinding` | 100% VolSync-scoped (`kyverno-generate-volsync`) |
| `kubernetes/kyverno/rbac/kustomization.yaml` | K8s `Kustomization` | Lists `rbac.yaml` only |
| `kubernetes/scripts/deploy-infrastructure.sh` | Bash script | `deploy_volsync()` function (L171–192), call (L230), probe (L254), case (L285–286); uses namespace `volsync-system` (legacy, separate from Flux path) |
| `AGENTS.md:98` | Docs | Mentions `volsync` under `storage/` in the directory tree |
| `.gitignore:2` | Config | `kubernetes/apps/*/volsync/generated/` — legacy path |
| `docs/superpowers/plans/2026-07-22-flatten-k8s-hierarchy.md` | Plan | Phase 7 task 7.1 lists two `dependsOn` entries per affected `ks.yaml`: `kopiur` and `volsync` |

Generated cluster objects that Flux will prune once their owners are deleted:

- 16 × `ReplicationSource/<pvc>-backup` (one per ceph-rbd PVC across 15 deployments)
- 16 × `ExternalSecret/volsync-kopia-<pvc>` (same set, Kyverno-generated)
- 16 × `Secret/volsync-kopia-<pvc>` (ESO materialization of the above)
- Intermediate `volsync-*` PVCs created by VolSync clones
- `ClusterRole/kyverno-generate-volsync` and its `ClusterRoleBinding`

## 5. Target State (what remains after the change)

- No VolSync manifests, no VolSync CRDs, no VolSync RBAC in the repository.
- No `HelmRelease/volsync`, no `HelmRepository/volsync`, no `ClusterPolicy/volsync-backup` in the cluster.
- No `ReplicationSource`, `ExternalSecret/volsync-*`, or `Secret/volsync-*` resources in the cluster.
- `kubernetes/storage/ns.yaml`, `rook-ceph`, and `openebs-localpv` are untouched.
- `kubernetes/kopiur-system/` is untouched; Kopiur's `ExternalSecret` continues to read `volsync-kopia-password` from 1Password (item is preserved under its current name).
- `docs/superpowers/plans/2026-07-22-flatten-k8s-hierarchy.md` Phase 7 task 7.1 keeps only the `kopiur` `dependsOn` lines; the `volsync` lines are removed.

## 6. Design

### 6.1 Phase 0 — flip prune flags first

Before any source-file deletion, flip `prune: false` → `prune: true` on the three Flux `Kustomization`s that own VolSync resources. This is delivered as its own commit pushed first so Flux reconciles with the new flag before any files vanish. Each sub-Kustomization's `prune: true` ensures that when the file is deleted in a later commit, the sub-Kustomization itself prunes its subtree during the same reconcile cycle, before Flux's GC kicks in.

| File | Block | Target | Why |
|---|---|---|---|
| `kubernetes/storage/volsync/ks.yaml` | `Kustomization/volsync` (the only doc) | `prune: true` | Owns `HelmRelease/volsync` |
| `kubernetes/kyverno/ks.yaml` | `Kustomization/kyverno-rbac` (the second doc) | `prune: true` | Owns `ClusterRole/kyverno-generate-volsync` and its `ClusterRoleBinding` |
| `kubernetes/kyverno/ks.yaml` | `Kustomization/kyverno-policies` (the third doc) | `prune: true` | Owns `ClusterPolicy/volsync-backup` and the generated `ExternalSecret`/`Secret`/`ReplicationSource` objects |

**The `Kustomization/kyverno` block (the first document in `kyverno/ks.yaml`) is intentionally left at `prune: false`.** Flipping it would prune the Kyverno Helm chart itself and uninstall the policy engine. The cluster root (`kubernetes/flux-config/cluster.yaml`) already has `prune: true` and is left alone.

### 6.2 Files to delete

1. `kubernetes/storage/volsync/ks.yaml`
2. `kubernetes/storage/volsync/app/kustomization.yaml`
3. `kubernetes/storage/volsync/app/helmrelease.yaml`
4. `kubernetes/storage/volsync/` (empty directory)
5. `kubernetes/flux-config/registry/helm/volsync.yaml`
6. `kubernetes/kyverno/policies/volsync-backup.yaml`
7. `kubernetes/kyverno/policies/kustomization.yaml` (becomes empty after step 6)
8. `kubernetes/kyverno/rbac/rbac.yaml`
9. `kubernetes/kyverno/rbac/kustomization.yaml` (becomes empty after step 8)

### 6.3 Files to edit

1. `kubernetes/storage/kustomization.yaml` — drop `- volsync/ks.yaml` (line 7)
2. `kubernetes/flux-config/registry/helm/kustomization.yaml` — drop `- volsync.yaml` (line 23)
3. `kubernetes/storage/volsync/ks.yaml` — `prune: false` → `prune: true` (Phase 0)
4. `kubernetes/kyverno/ks.yaml` — flip `prune: false` → `prune: true` on the `kyverno-rbac` block (line 34) and the `kyverno-policies` block (line 52) only; leave the `kyverno` block at `prune: false` to avoid pruning the Kyverno Helm chart itself (Phase 0)
5. `kubernetes/scripts/deploy-infrastructure.sh` — remove `deploy_volsync()` function (L171–192), its call from `deploy_all` (L230), the status probe (L254), and the `"volsync"|"backup"` case branch (L285–286)
6. `AGENTS.md` line 98 — drop `volsync` from the `storage/` directory listing
7. `.gitignore` line 2 — drop the legacy `kubernetes/apps/*/volsync/generated/` path
8. `docs/superpowers/plans/2026-07-22-flatten-k8s-hierarchy.md` — in Phase 7 / Task 7.1, remove every `volsync` `dependsOn` entry; keep the `kopiur` entries only

### 6.4 Order of operations

1. **Phase 0** — commit and push the prune-flag flips from §6.1. Wait for Flux to reconcile (or `flux reconcile kustomization cluster -n flux-system`).
2. **Phases 1–5** — each removes a logical layer (VolSync HelmRelease, HelmRepository, Kyverno policy, RBAC, docs/scripts). Commit and push each phase separately. Flux reconciles between phases; verify no orphans.
3. **Phase 6** — run the CI validation commands locally.
4. **Phase 7** — verify the cluster is clean and run the explicit `kubectl delete` for cluster-scoped RBAC objects.

### 6.5 Cluster verification commands

```bash
# Source: every Kustomization, no VolSync references
for dir in kubernetes/flux-config kubernetes; do
  kustomize build "$dir" | kubeconform -strict -ignore-missing-schemas \
    -schema-location default \
    -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
done

# Cluster: no VolSync resources remain
kubectl get hr -A | grep -i volsync                                # expect no output
kubectl get replicationsources.volsync.backube -A                 # expect no output
kubectl get externalsecret -A | grep volsync-                     # expect no output
kubectl get secret -A | grep volsync-kopia                        # expect no output
kubectl get clusterpolicy | grep volsync                          # expect no output
kubectl get clusterrole,clusterrolebinding | grep volsync         # expect no output
kubectl get pvc -A | grep '^volsync-'                             # expect no output
```

### 6.6 Out-of-band cluster cleanup

`ClusterRole/kyverno-generate-volsync` and its `ClusterRoleBinding` are cluster-scoped and Flux's GC behavior for cluster-scoped children is implementation-defined. As a safety net, after Phase 4 reconcile succeeds, run:

```bash
kubectl delete clusterrole kyverno-generate-volsync
kubectl delete clusterrolebinding kyverno-generate-volsync
```

If they were already pruned by the cluster root with `prune: true`, the commands will report "not found" — that is fine.

### 6.7 Rollback

If backups were missed or a dependent app surfaces a bug:

1. Revert the Phase 0 commit. The three `prune: false` flags are restored; Flux re-reconciles.
2. Revert each subsequent deletion commit in reverse order. Flux re-reconciles after each.
3. `flux reconcile kustomization cluster -n flux-system` reinstalls `HelmRelease/volsync`, the Kyverno policy, and the generated `ExternalSecret`/`ReplicationSource` objects.
4. Re-run `kubectl apply` (or let Flux reconcile) for the deleted `ClusterRole`/`ClusterRoleBinding`.
5. The historical Backblaze B2 bucket data is still available because §3 left it untouched.

## 7. Out-of-band follow-ups (not part of this PR)

These are listed for visibility; they are explicitly excluded from this change.

1. **1Password rename.** The item `volsync-kopia-password` is now a misnomer. Rename in 1Password to `kopiur-kopia-password`, then update `kubernetes/kopiur-system/kopiur/repository/externalsecret.yaml:18` in a follow-up PR.
2. **Backblaze B2 cleanup.** Bucket `s3://whoverse-k8s-backups/volsync/` retains ~3 months of snapshots per the policy's retention (7d/4w/3m). Decide retention or deletion in a separate task.
3. **`deploy-infrastructure.sh` legacy path.** The script deploys to namespace `volsync-system`, distinct from the Flux path's `storage`. Any historical install into `volsync-system` will not be pruned. Verify with `kubectl get ns volsync-system` and clean up if present.

## 8. Validation

Build validation: the two CI `kustomize build` invocations in `.github/workflows/validate-kubernetes.yml` must succeed after the change. Run locally:

```bash
for dir in kubernetes/flux-config kubernetes; do
  echo "=== $dir ==="
  kustomize build "$dir" | kubeconform -strict -ignore-missing-schemas \
    -schema-location default \
    -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
done
```

Cluster validation: §6.5 commands.

## 9. Risks and Mitigations

| Risk | Mitigation |
|---|---|
| Forgetting one of the three `prune: true` flips leaves orphan cluster resources | The plan executes Phase 0 first as a separate commit; CI's `kustomize build` would still pass but the verification commands in §6.5 catch orphans |
| Phase 0 flips prune on `Kustomization/kyverno` and prunes Kyverno itself | `kyverno` block is explicitly excluded from the flips; only `kyverno-rbac` and `kyverno-policies` are touched |
| Third-party chart repo `perfectra1n/volsync` vs upstream `backube/volsync` divergence | Irrelevant for removal; flagged for future investigation only |
| VolSync intermediate PVCs (`volsync-*`) left on the Ceph RBD pool | §6.5 includes `kubectl get pvc -A | grep '^volsync-'`; if any remain, delete manually |
| `default/memos` loses its (unused) backup with no replacement | Confirmed by user; memos is unused |
| Shared 1Password item `volsync-kopia-password` becomes a misnomer | Listed as out-of-band follow-up; no rename in this PR |
| Backblaze B2 bucket orphans | Listed as out-of-band follow-up; data preserved for now |
| `deploy-infrastructure.sh` legacy `volsync-system` namespace | Verification step in §7.3 |

## 10. Open Questions

None. All questions raised during brainstorming are resolved: backup replacement (Kopiur already covers all used apps), `memos` (unused), Backblaze data (preserve), 1Password item (deferred), chart repo fork (irrelevant).

## 11. Implementation Plan

A separate plan will be generated via the `writing-plans` skill after this spec is reviewed.