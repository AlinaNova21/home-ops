# Fold `flux-config` into `flux-system` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the stale, self-referential `kubernetes/flux-config/` bootstrap layer and fold its content into `kubernetes/flux-system/` as a standard `flux-config` component (ks.yaml + app/), following the repo's Namespace → Component → Resources hierarchy.

**Architecture:** The current setup has two independent Flux reconciliation stacks: (1) a bootstrap stack `Kustomization/flux-system` → `./kubernetes/flux-config` (sourced from OCI, dangling) and (2) the app stack `Kustomization/cluster` → `./kubernetes` (sourced from Git). The OCI path is dormant and its artifact is stale, so `flux.whoverse.dev` reports an old sha. The refactor deletes the obsolete OCI source and the whole `kubernetes/flux-config/` dir, replacing it with a single `flux-config` component under `flux-system/` (git-sourced, SOPS-decrypting, defines the `GitRepository/home-ops` root source). The GitRepository bootstrap circularity is intended: an initial manual apply of the flux-system tree creates the source, after which Flux reconciles it.

**Tech Stack:** Flux CD v2 (kustomize-controller/source-controller), Kustomize, SOPS, kubeconform, flate. No app code — pure manifest refactor.

---

## File Structure (map)

| File | Action |
|---|---|
| `kubernetes/flux-system/flux-config/ks.yaml` | Create — `Kustomization flux-config` (git source, SOPS decrypt, healthchecks) |
| `kubernetes/flux-system/flux-config/app/kustomization.yaml` | Create — flat resources list |
| `kubernetes/flux-system/flux-config/app/gitrepository.yaml` | Create — `GitRepository/home-ops` (flattened from old `registry/git/`) |
| `kubernetes/flux-system/flux-config/app/onepassword-connect-secret.sops.yaml` | Move — from `kubernetes/flux-config/sops/` |
| `kubernetes/flux-system/kustomization.yaml` | Modify — add `flux-config/ks.yaml` to resources |
| `.sops.yaml` | Modify — update Flux-managed secret path regex |
| `.github/workflows/validate-kubernetes.yml` | Modify — update kustomize build dir loop |
| `Justfile` | Modify — `bootstrap-sops-key` comment + reconcile target |
| `AGENTS.md` | Modify — update flux-config references |
| `kubernetes/flux-config/**` | Delete — entire old bootstrap dir |

Then no live-cluster action (handled separately by operator after push).

---

## Task 1: Create the `flux-config` component (ks.yaml + app/)

**Files:**
- Create: `kubernetes/flux-system/flux-config/ks.yaml`
- Create: `kubernetes/flux-system/flux-config/app/kustomization.yaml`
- Create: `kubernetes/flux-system/flux-config/app/gitrepository.yaml`

- [ ] **Step 1: Create `kubernetes/flux-system/flux-config/ks.yaml`**

Merge the old `Kustomization/flux-system` (self-ref + healthchecks) and `Kustomization/flux-sops` (SOPS decrypt) into one component Kustomization that reconciles `./app`:

```yaml
---
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/kustomize.toolkit.fluxcd.io/kustomization_v1.json
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: flux-config
  namespace: flux-system
spec:
  interval: 10m
  path: "./kubernetes/flux-system/flux-config/app"
  sourceRef:
    kind: GitRepository
    name: home-ops
  decryption:
    provider: sops
    secretRef:
      name: sops-age
  healthChecks:
    - apiVersion: fluxcd.controlplane.io/v1
      kind: FluxInstance
      name: flux
      namespace: flux-system
    - apiVersion: v1
      kind: Secret
      name: onepassword-connect
      namespace: onepassword-connect
  timeout: 5m
  wait: true
  prune: true
```

- [ ] **Step 2: Create `kubernetes/flux-system/flux-config/app/kustomization.yaml`**

List resources flat (repos sit next to secrets, mirroring the rest of the repo):

```yaml
---
# yaml-language-server: $schema=https://json.schemastore.org/kustomization
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - gitrepository.yaml
  - onepassword-connect-secret.sops.yaml
```

- [ ] **Step 3: Create `kubernetes/flux-system/flux-config/app/gitrepository.yaml`**

Flattened from old `kubernetes/flux-config/registry/git/gitrepository.yaml` (unchanged spec):

```yaml
---
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/source.toolkit.fluxcd.io/gitrepository_v1.json
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: home-ops
  namespace: flux-system
spec:
  interval: 10m
  ref:
    branch: main
  url: https://github.com/AlinaNova21/home-ops
```

- [ ] **Step 4: Move the SOPS secret**

```bash
git mv kubernetes/flux-config/sops/onepassword-connect-secret.sops.yaml \
       kubernetes/flux-system/flux-config/app/onepassword-connect-secret.sops.yaml
mkdir -p kubernetes/flux-system/flux-config/app
```

- [ ] **Step 5: Validate the new component builds**

```bash
kustomize build kubernetes/flux-system/flux-config/app | kubeconform \
  -strict -ignore-missing-schemas \
  -schema-location default \
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
```
Expected: no failures; output contains `GitRepository/home-ops` and `Secret/onepassword-connect`.

- [ ] **Step 6: Commit**

```bash
git add kubernetes/flux-system/flux-config
git commit -m "feat(flux-config): fold flux-config into flux-system as a component"
```

---

## Task 2: Register the component + drop the old bootstrap tree

**Files:**
- Modify: `kubernetes/flux-system/kustomization.yaml`
- Delete: `kubernetes/flux-config/` (whole dir)

- [ ] **Step 1: Add `flux-config/ks.yaml` to `kubernetes/flux-system/kustomization.yaml`**

Current:
```yaml
resources:
  - ns.yaml
  - webhook/ks.yaml
  - flux-operator/ks.yaml
  - flux-instance/ks.yaml
```
New — add `flux-config/ks.yaml` (keep namespace first):
```yaml
resources:
  - ns.yaml
  - flux-config/ks.yaml
  - webhook/ks.yaml
  - flux-operator/ks.yaml
  - flux-instance/ks.yaml
```

- [ ] **Step 2: Delete the old bootstrap directory**

```bash
git rm -r kubernetes/flux-config
```

This removes: `namespace.yaml` (duplicate Namespace), `kustomization.yaml`, `flux-system.yaml` (self-ref), `registries.yaml` (flux-registries), `sops/ks.yaml` (flux-sops), and the `registry/{git,helm,oci}/` subtree including the dormant `OCIRepository/home-ops` and the unused `openebs` HelmRepository.

- [ ] **Step 3: Confirm no orphaned references remain in the tree**

```bash
grep -rn 'flux-config' kubernetes/ | grep -v 'kubernetes/flux-system/flux-config' || echo "clean"
```
Expected: only the new `kubernetes/flux-system/flux-config` path appears.

- [ ] **Step 4: Run flate test**

```bash
just flate-test
```
Expected: `174 passed` (or same count as baseline — no new/dropped app Kustomizations at this point; the `flux-config` Kustomization may or may not be enumerated by flate depending on its source registration).

- [ ] **Step 5: Commit**

```bash
git add -A kubernetes/flux-system kubernetes/flux-config
git commit -m "refactor(flux-config): remove kubernetes/flux-config, register flux-config component"
```

---

## Task 3: Update cross-cutting references (CI, SOPS, Justfile, docs)

**Files:**
- Modify: `.sops.yaml`
- Modify: `.github/workflows/validate-kubernetes.yml`
- Modify: `Justfile`
- Modify: `AGENTS.md`

- [ ] **Step 1: Update `.sops.yaml` Flux-managed secret regex**

Current:
```yaml
  - path_regex: kubernetes/flux-config/sops/.*\.sops\.yaml$
```
New (the SOPS file now lives at `kubernetes/flux-system/flux-config/app/`):
```yaml
  - path_regex: kubernetes/flux-system/flux-config/.*\.sops\.yaml$
```

- [ ] **Step 2: Update CI kustomize build loop**

In `.github/workflows/validate-kubernetes.yml`, current line:
```yaml
          for dir in kubernetes/flux-config kubernetes; do
```
New (flux-config is now part of `kubernetes/flux-system`, covered by the root build; the SOPS-decrypting `flux-config` Kustomization is validated by flate locally, but keep the root `kubernetes` build as the CI-equivalent schema gate):
```yaml
          for dir in kubernetes; do
```

- [ ] **Step 3: Update `Justfile` `bootstrap-sops-key`**

Current comment + reconcile:
```makefile
# flux-sops Kustomization which decrypts and applies the 1Password Connect
# credentials Secret from kubernetes/flux-config/sops/.
...
    flux reconcile kustomization flux-sops -n flux-system
```
New:
```makefile
# flux-config Kustomization which decrypts and applies the 1Password Connect
# credentials Secret from kubernetes/flux-system/flux-config/app/.
...
    flux reconcile kustomization flux-config -n flux-system
```

- [ ] **Step 4: Update `AGENTS.md`**

- Line ~165 meta-dir table: change the `flux-config/` row to reflect it is now a component under `kubernetes/flux-system/` (GitRepository + registry sources + SOPS secret). If the row describes a top-level meta dir, update or remove it.
- Line ~222 + ~236 CI sections: change `for dir in kubernetes/flux-config kubernetes` → `kubernetes`.
- Line ~309 comment: update `kubernetes/flux-config/sops` → `kubernetes/flux-system/flux-config`.

- [ ] **Step 5: Validate**

```bash
just flate-test
pre-commit run --all-files
```
Expected: `174 passed` (flate), gitleaks + trufflehog clean.

- [ ] **Step 6: Commit**

```bash
git add .sops.yaml .github/workflows/validate-kubernetes.yml Justfile AGENTS.md
git commit -m "chore(flux-config): update CI, SOPS regex, Justfile, and docs for flux-config move"
```

---

## Verification

- [ ] **Task 2/3 flate build** — `just flate-test` returns the same pass count as baseline (174).
- [ ] **CI-equivalent schema check (root build)** —
```bash
kustomize build kubernetes | kubeconform -strict -ignore-missing-schemas \
  -schema-location default \
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
```
Expected: 0 failures.
- [ ] **No stale refs** — `grep -rn 'kubernetes/flux-config' kubernetes/ AGENTS.md Justfile .sops.yaml .github` returns only the new `kubernetes/flux-system/flux-config` path (or the `.sops.yaml` regex on the new path).

## Rollback

If pushed and Flux reconciles badly:
1. `flux suspend kustomization flux-config -n flux-system`
2. Revert the merge commit on `main` (re-introduce `kubernetes/flux-config/`, restore `Kustomization/flux-system` self-ref and OCI source).
3. Reconcile: `flux reconcile kustomization cluster -n flux-system`.

## Notes / Deferred

- The old `OCIRepository/home-ops` (dormant, `latest@sha256:627f3dc`) was already suspended on the live cluster and is dropped from the tree in Task 2. Do NOT re-add it.
- The `FluxReport.sync.id` will change from `kustomization/flux-system` to `kustomization/flux-config` once the new component is applied — expected, not an error.
- Bootstrap of a fresh cluster = manually `kubectl apply -k kubernetes/flux-system` (creates the `GitRepository/home-ops` root source + `flux-config` Kustomization), then Flux takes over. This preserves the intended circular bootstrap property.
