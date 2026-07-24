# Drop VolSync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove every VolSync manifest, RBAC, repository, policy, and docs reference from `home-ops`; rely on Flux's prune (after Phase 0 flips) to clean cluster state.

**Architecture:** Phase 0 flips `prune: false` → `prune: true` on three Flux `Kustomization`s as a separate commit pushed first. Each subsequent phase deletes one logical layer (HelmRelease, HelmRepository, Kyverno policy, RBAC, docs/scripts). Each phase is its own commit and push; Flux reconciles between phases. Phase 6 runs CI-equivalent validation; Phase 7 verifies cluster is clean and runs a safety-net `kubectl delete` for cluster-scoped RBAC.

**Tech Stack:** Flux CD (prune + GC), Kustomize, Kyverno, External Secrets Operator, GitHub Actions (`validate-kubernetes.yml`), 1Password Connect.

**Spec:** `docs/superpowers/specs/2026-07-23-drop-volsync-design.md`

---

## Phase 0 — Enable pruning on VolSync-relevant Flux `Kustomization`s

**Files:**
- Modify: `kubernetes/storage/volsync/ks.yaml:23`
- Modify: `kubernetes/kyverno/ks.yaml:34` (`kyverno-rbac` block)
- Modify: `kubernetes/kyverno/ks.yaml:52` (`kyverno-policies` block)

- [ ] **Step 1: Flip `prune: false` → `prune: true` in `kubernetes/storage/volsync/ks.yaml`**

Edit line 23:
```yaml
  prune: true
```

- [ ] **Step 2: Flip `prune: false` → `prune: true` in `kubernetes/kyverno/ks.yaml` `kyverno-rbac` block**

Edit line 34:
```yaml
  prune: true
```

(Leave the `kyverno` block at line 16 untouched. Flipping it would prune the Kyverno Helm chart itself.)

- [ ] **Step 3: Flip `prune: false` → `prune: true` in `kubernetes/kyverno/ks.yaml` `kyverno-policies` block**

Edit line 52:
```yaml
  prune: true
```

- [ ] **Step 4: Verify locally**

```bash
grep -n 'prune:' kubernetes/storage/volsync/ks.yaml kubernetes/kyverno/ks.yaml
```

Expected: three `prune: true` lines (one in `storage/volsync/ks.yaml:23`, two in `kyverno/ks.yaml`) and one `prune: false` (the `kyverno` Helm block at line 16).

- [ ] **Step 5: Commit and push**

```bash
git add kubernetes/storage/volsync/ks.yaml kubernetes/kyverno/ks.yaml
git -c user.email=agent@home-ops.local -c user.name=opencode commit -m "chore(flux): enable prune on volsync-related Kustomizations" -m "Phase 0 of dropping VolSync. Each Kustomization now prunes its own subtree before its source file is removed in subsequent phases. The kyverno Helm block is left at prune: false to avoid uninstalling the policy engine itself."
git push origin main
```

- [ ] **Step 6: Wait for Flux to reconcile**

```bash
flux reconcile kustomization cluster -n flux-system
flux get kustomizations -A
```

Expected: all Kustomizations `Ready=True`. No VolSync resources deleted yet (no source files have been removed).

---

## Phase 1 — Delete `kubernetes/storage/volsync/` (HelmRelease layer)

**Files:**
- Delete: `kubernetes/storage/volsync/ks.yaml`
- Delete: `kubernetes/storage/volsync/app/kustomization.yaml`
- Delete: `kubernetes/storage/volsync/app/helmrelease.yaml`
- Delete: `kubernetes/storage/volsync/` (empty dir)
- Modify: `kubernetes/storage/kustomization.yaml` (line 7)

- [ ] **Step 1: Delete the directory tree**

```bash
git rm -r kubernetes/storage/volsync/
```

- [ ] **Step 2: Edit `kubernetes/storage/kustomization.yaml` — drop the `volsync/ks.yaml` reference**

Current line 7:
```yaml
  - volsync/ks.yaml
```

Remove that line. The file becomes:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ns.yaml
  - openebs-localpv/ks.yaml
  - rook-ceph/ks.yaml
```

- [ ] **Step 3: Commit and push**

```bash
git add kubernetes/storage/kustomization.yaml
git -c user.email=agent@home-ops.local -c user.name=opencode commit -m "chore(k8s): remove volsync HelmRelease" -m "Phase 1 of dropping VolSync. The Flux Kustomization/volsync prunes HelmRelease/volsync from the cluster during the next reconcile cycle because prune: true was enabled in Phase 0."
git push origin main
```

- [ ] **Step 4: Verify the HelmRelease is gone**

```bash
flux reconcile kustomization cluster -n flux-system
kubectl get helmrelease -n storage volsync
```

Expected: `Error from server (NotFound): helmreleases.helm.toolkit.fluxcd.io "volsync" not found`.

- [ ] **Step 5: Verify no VolSync pods remain**

```bash
kubectl get pods -n storage | grep volsync
kubectl get pvc -A | grep '^volsync-'
```

Expected: no output. If `volsync-*` PVCs linger, list them and delete manually (they're owned by the now-removed HelmRelease and Flux GC may not reach them).

---

## Phase 2 — Delete `HelmRepository/volsync`

**Files:**
- Delete: `kubernetes/flux-config/registry/helm/volsync.yaml`
- Modify: `kubernetes/flux-config/registry/helm/kustomization.yaml` (line 23)

- [ ] **Step 1: Delete the repository file**

```bash
git rm kubernetes/flux-config/registry/helm/volsync.yaml
```

- [ ] **Step 2: Edit `kubernetes/flux-config/registry/helm/kustomization.yaml` — drop line 23**

Current line 23:
```yaml
  - volsync.yaml
```

Remove that line.

- [ ] **Step 3: Commit and push**

```bash
git add kubernetes/flux-config/registry/helm/kustomization.yaml
git -c user.email=agent@home-ops.local -c user.name=opencode commit -m "chore(flux): remove volsync HelmRepository" -m "Phase 2 of dropping VolSync. The cluster root has prune: true, so the HelmRepository/volsync resource is removed from the cluster during the next reconcile."
git push origin main
```

- [ ] **Step 4: Verify**

```bash
flux reconcile kustomization cluster -n flux-system
kubectl get helmrepository -n flux-system volsync
```

Expected: `Error from server (NotFound): helmrepositories.source.toolkit.fluxcd.io "volsync" not found`.

---

## Phase 3 — Delete `ClusterPolicy/volsync-backup` and generated Kyverno objects

**Files:**
- Delete: `kubernetes/kyverno/policies/volsync-backup.yaml`
- Delete: `kubernetes/kyverno/policies/kustomization.yaml` (becomes empty)

- [ ] **Step 1: Delete the policy file**

```bash
git rm kubernetes/kyverno/policies/volsync-backup.yaml
```

- [ ] **Step 2: Delete the now-empty kustomization file**

```bash
git rm kubernetes/kyverno/policies/kustomization.yaml
```

(The file contains only `- volsync-backup.yaml` after Step 1; deleting it leaves the parent `kubernetes/kyverno/app/` or `kubernetes/kyverno/` kustomization referencing a missing directory. Check the referencing file before committing.)

- [ ] **Step 3: Inspect the parent reference**

```bash
grep -rn 'policies' kubernetes/kyverno/
```

Expected output reveals where `policies/` is referenced. If any reference lists the directory itself (not specific files), no further edit is needed. If a reference points at `policies/kustomization.yaml` specifically, leave the directory in place but ensure the directory contains no manifest files (which it won't after Step 1–2).

- [ ] **Step 4: Commit and push**

```bash
git add kubernetes/kyverno/policies/
git -c user.email=agent@home-ops.local -c user.name=opencode commit -m "chore(k8s): remove kyverno volsync-backup policy" -m "Phase 3 of dropping VolSync. Removing the ClusterPolicy triggers Kyverno's generate controller to clean up the 16 ReplicationSource, ExternalSecret, and Secret objects it had been creating."
git push origin main
```

- [ ] **Step 5: Verify Kyverno objects are gone**

```bash
flux reconcile kustomization cluster -n flux-system
sleep 30  # Kyverno GC runs on its reconcile interval
kubectl get replicationsources.volsync.backube -A
kubectl get externalsecret -A | grep volsync-
kubectl get secrets -A | grep volsync-kopia
kubectl get clusterpolicy volsync-backup
```

Expected: all four commands report no output / not found. If `ReplicationSource` objects linger, force-delete:
```bash
kubectl delete replicationsources.volsync.backube --all -A
```

---

## Phase 4 — Delete Kyverno RBAC

**Files:**
- Delete: `kubernetes/kyverno/rbac/rbac.yaml`
- Delete: `kubernetes/kyverno/rbac/kustomization.yaml` (becomes empty)

- [ ] **Step 1: Delete the RBAC file**

```bash
git rm kubernetes/kyverno/rbac/rbac.yaml
```

- [ ] **Step 2: Delete the now-empty kustomization file**

```bash
git rm kubernetes/kyverno/rbac/kustomization.yaml
```

- [ ] **Step 3: Inspect the parent reference**

```bash
grep -rn 'rbac' kubernetes/kyverno/
```

Expected: confirms no parent Kustomization requires the directory to exist. The `kyverno-rbac` Flux Kustomization in `kubernetes/kyverno/ks.yaml` reconciles `./kyverno/rbac` — once empty, it reconciles to nothing.

- [ ] **Step 4: Commit and push**

```bash
git add kubernetes/kyverno/rbac/
git -c user.email=agent@home-ops.local -c user.name=opencode commit -m "chore(k8s): remove kyverno volsync RBAC" -m "Phase 4 of dropping VolSync. The ClusterRole and ClusterRoleBinding are pruned by the cluster root. A safety-net kubectl delete in Phase 7 catches any cluster-scoped resource Flux GC does not reach."
git push origin main
```

- [ ] **Step 5: Verify Flux Kustomization reconciles to nothing**

```bash
flux reconcile kustomization cluster -n flux-system
flux get kustomizations -n kyverno
```

Expected: `kyverno-rbac` and `kyverno-policies` both `Ready=True` with no managed resources.

---

## Phase 5 — Clean docs, scripts, and legacy references

**Files:**
- Modify: `kubernetes/scripts/deploy-infrastructure.sh`
- Modify: `AGENTS.md`
- Modify: `.gitignore`
- Modify: `docs/superpowers/plans/2026-07-22-flatten-k8s-hierarchy.md`

- [ ] **Step 1: Edit `kubernetes/scripts/deploy-infrastructure.sh`**

Remove four blocks:
- Lines 171–192: the `deploy_volsync()` function definition (from `deploy_volsync() {` through the closing `}`)
- Line 230: the `deploy_volsync` call inside `deploy_all`
- Line 254: the status probe `kubectl get pods -n volsync-system | grep volsync`
- Lines 285–286: the case branch `"volsync"|"backup") deploy_volsync ;;`

Verify after editing:
```bash
grep -n -i 'volsync' kubernetes/scripts/deploy-infrastructure.sh
```

Expected: no output.

- [ ] **Step 2: Edit `AGENTS.md` line 98 — drop `volsync` from the `storage/` listing**

Find the line that reads:
```
│   ├── storage/                  # rook-ceph, openebs-localpv, volsync
```

Replace with:
```
│   ├── storage/                  # rook-ceph, openebs-localpv
```

- [ ] **Step 3: Edit `.gitignore` line 2 — drop the legacy `volsync` path**

Current line 2:
```
kubernetes/apps/*/volsync/generated/
```

Remove that line entirely.

- [ ] **Step 4: Edit `docs/superpowers/plans/2026-07-22-flatten-k8s-hierarchy.md`**

In Phase 7 / Task 7.1, remove every `volsync` entry from each affected `ks.yaml`'s `dependsOn` list. Keep only the `kopiur` entry.

Before:
```yaml
  dependsOn:
    - name: rook-ceph
    - name: kopiur
      namespace: kopiur-system
    - name: volsync
      namespace: storage
```

After:
```yaml
  dependsOn:
    - name: rook-ceph
    - name: kopiur
      namespace: kopiur-system
```

Apply to all 15 `ks.yaml` files listed in the flatten plan's Phase 7 / Task 7.1 block.

- [ ] **Step 5: Verify no stray references remain in docs/scripts/.gitignore**

```bash
grep -rn -i 'volsync' kubernetes/scripts/ AGENTS.md .gitignore docs/superpowers/
```

Expected: only references in `docs/superpowers/specs/2026-07-23-drop-volsync-design.md` and `docs/superpowers/plans/2026-07-23-drop-volsync.md` (this plan). All other matches should be gone.

- [ ] **Step 6: Commit and push**

```bash
git add kubernetes/scripts/deploy-infrastructure.sh AGENTS.md .gitignore docs/superpowers/plans/2026-07-22-flatten-k8s-hierarchy.md
git -c user.email=agent@home-ops.local -c user.name=opencode commit -m "chore: remove volsync references from docs, scripts, and legacy paths" -m "Phase 5 of dropping VolSync. Clean up deploy-infrastructure.sh, AGENTS.md tree listing, .gitignore legacy path, and the flatten plan's Phase 7 volsync dependsOn entries."
git push origin main
```

---

## Phase 6 — Local validation

- [ ] **Step 1: Run kustomize build + kubeconform against `kubernetes/flux-config`**

```bash
kustomize build kubernetes/flux-config | kubeconform -strict -ignore-missing-schemas \
  -schema-location default \
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
```

Expected: exit 0, no errors.

- [ ] **Step 2: Run kustomize build + kubeconform against `kubernetes/`**

```bash
kustomize build kubernetes | kubeconform -strict -ignore-missing-schemas \
  -schema-location default \
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
```

Expected: exit 0, no errors. No `volsync.backube/v1alpha1` references in the output.

- [ ] **Step 3: Verify the cluster root build has no VolSync resources**

```bash
kustomize build kubernetes | grep -i 'volsync\|kyverno-generate-volsync'
```

Expected: no output.

- [ ] **Step 4: If any validation step fails, fix and commit**

```bash
git add -A
git -c user.email=agent@home-ops.local -c user.name=opencode commit -m "fix: address validation findings from phase 6"
git push origin main
```

---

## Phase 7 — Cluster verification and safety-net cleanup

- [ ] **Step 1: Force a final reconcile**

```bash
flux reconcile kustomization cluster -n flux-system
flux reconcile source oci home-ops -n flux-system
```

- [ ] **Step 2: Run all verification commands from spec §6.5**

```bash
kubectl get hr -A | grep -i volsync
kubectl get replicationsources.volsync.backube -A
kubectl get externalsecret -A | grep volsync-
kubectl get secrets -A | grep volsync-kopia
kubectl get clusterpolicy | grep volsync
kubectl get clusterrole,clusterrolebinding | grep volsync
kubectl get pvc -A | grep '^volsync-'
```

Expected: every command reports no output / not found.

- [ ] **Step 3: Safety-net RBAC delete**

```bash
kubectl delete clusterrole kyverno-generate-volsync
kubectl delete clusterrolebinding kyverno-generate-volsync
```

If both report "not found", that confirms Phase 4's pruning already cleaned them up. If they were still present, the delete is now permanent.

- [ ] **Step 4: Check for the legacy `volsync-system` namespace**

```bash
kubectl get namespace volsync-system
```

If present:
```bash
kubectl delete namespace volsync-system
```

- [ ] **Step 5: Verify the cluster root is still healthy**

```bash
flux get kustomizations -A
```

Expected: every Kustomization `Ready=True`.

- [ ] **Step 6: Confirm `kyverno` Helm chart is still installed**

```bash
kubectl get pods -n kyverno
```

Expected: Kyverno admission + background controllers running. (Phase 0 explicitly did not flip `Kustomization/kyverno` to `prune: true`.)

---

## Done

All Phases 0–7 complete. Out-of-band follow-ups (deferred per spec §7):
- Rename 1Password item `volsync-kopia-password` → `kopiur-kopia-password` and update `kubernetes/kopiur-system/kopiur/repository/externalsecret.yaml:18`.
- Decide retention vs. deletion of Backblaze B2 bucket `s3://whoverse-k8s-backups/volsync/`.