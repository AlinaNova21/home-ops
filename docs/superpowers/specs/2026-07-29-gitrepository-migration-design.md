# OCIRepository → GitRepository Migration

**Status:** Approved
**Date:** 2026-07-29
**Scope:** Runtime changes only (AGENTS.md / home-ops-add-new-app skill updates deferred)

## Goal

Replace `OCIRepository/home-ops` (consumed by all 68 Flux `Kustomization`s) with `GitRepository/home-ops`, allowing direct git-based reconciles from the GitHub repository without an intermediate OCI artifact build step.

## Decisions

| Decision | Choice |
|---|---|
| Source kind | `GitRepository` |
| URL | `https://github.com/AlinaNova21/home-ops` |
| Ref | `spec.ref.branch=main` |
| Interval | `10m` (matches current OCI interval) |
| Auth | Anonymous (no `secretRef`, no `provider`) |
| Source root | Repo root (`./`) |
| Path layout | Every `Kustomization.spec.path` gains a `./kubernetes` prefix |
| OCIRepository/home-ops fate | Retained as dormant manifest (rollback target) |
| Receiver wiring | `spec.resources[0].kind: GitRepository`; apiVersion/name/namespace unchanged |
| Alert wiring | Add parallel `eventSources` entry for `kind: GitRepository`; keep existing OCIRepository wildcard |
| Justfile | Keep OCI-coupled recipes dormant; add Git-flavored equivalents; extend `flux-status`/`destroy-flux` to cover both kinds |
| GitHub Actions | `kubernetes-oci.yml` suspended (no triggers); retained in tree |
| Cutover sequencing | Approach A: single atomic mega-commit + manual bootstrap of the GitRepository manifest and root `Kustomization/cluster` only; the remaining 67 Kustomizations self-reconcile |
| Docs / skills | Deferred to follow-up PR |
| Migration approach | Approach A (single atomic commit) — chosen over B/C for fastest cutover and clearest rollback |

## Changes

### Source manifest (new)

`kubernetes/flux-config/registry/git/gitrepository.yaml`:

```yaml
---
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

The empty `kubernetes/flux-config/registry/git/kustomization.yaml` aggregator already lists `git/` for `Kustomization/flux-registries`. No aggregator change required.

### Source manifest (dormant, retained)

`kubernetes/flux-config/registry/oci/ocirepository.yaml` — no edits; remains reconcilable for emergency rollback.

### Root Kustomization

`kubernetes/ks.yaml`:

- `spec.path`: `./` → `./kubernetes`
- `spec.sourceRef.kind`: `OCIRepository` → `GitRepository`
- `spec.sourceRef.name`: `home-ops` (unchanged)
- `spec.sourceRef.namespace`: `flux-system` (unchanged)

### Three flux-config Kustomizations

| File | Spec.path change | Spec.sourceRef.kind change |
|---|---|---|
| `kubernetes/flux-config/flux-system.yaml` | `./flux-config` → `./kubernetes/flux-config` | OCIRepository → GitRepository |
| `kubernetes/flux-config/registries.yaml` | `./flux-config/registry` → `./kubernetes/flux-config/registry` | OCIRepository → GitRepository |
| `kubernetes/flux-config/sops/ks.yaml` | `./flux-config/sops` → `./kubernetes/flux-config/sops` | OCIRepository → GitRepository |

### 64 component `ks.yaml` files

For every file under `kubernetes/**/ks.yaml` (excluding the three above), apply:

- `spec.path`: prepend `./kubernetes/` to the existing path value.
- `spec.sourceRef.kind`: `OCIRepository` → `GitRepository`.

In total: **65 files, 68 Kustomizations, 68 `spec.path` edits, 82 `sourceRef.kind` edits** (some files contain multiple Kustomizations).

### Receiver (`kubernetes/flux-system/webhook/app/webhook-receiver.yaml`)

`spec.resources[0]` — change `kind: OCIRepository` to `kind: GitRepository`. `apiVersion: source.toolkit.fluxcd.io/v1`, `name: home-ops`, `namespace: flux-system` unchanged. The Receiver triggers on `home-ops` only; the 50 upstream-chart OCIRepositories are unaffected by GitHub push events.

### Alert (`kubernetes/flux-system/webhook/app/webhook-alert.yaml`)

Append a parallel `eventSources` entry:

```yaml
- kind: GitRepository
  name: '*'
  namespace: flux-system
```

Keep the existing `kind: OCIRepository` wildcard — 50 upstream-chart OCIRepositories still fire events.

### Justfile

- Add a new variable `git_url := "https://github.com/AlinaNova21/home-ops"` alongside the existing `oci_url`.
- Add Git-flavored recipes `git-flux-sync` and `git-deploy` that `kubectl annotate gitrepository/home-ops -n flux-system reconcile.fluxcd.io/requestedAt=...` and `flux reconcile kustomization cluster -n flux-system`.
- Extend `flux-status` to list both `ocirepositories` and `gitrepositories`.
- Extend `destroy-flux` to delete both kinds (`-n flux-system`).
- **No change** to existing `flux-push`, `flux-sync`, `deploy` — left as dormant helpers for emergency OCI rollback. They remain functional; the `oci_url` variable stays.

### GitHub Actions

`kubernetes-oci.yml`: replace its trigger (push / `workflow_dispatch`) with `on: { workflow_dispatch: }` and gate the build job with `if: ${{ false }}` to suppress execution. File retained for historical reference.

## Cutover procedure

1. Branch `feat/gitrepository-migration` off `main`.
2. Apply all file changes listed above as one commit.
3. Run `pre-commit run --all-files` locally.
4. Open PR; CI (`validate-kubernetes.yml`) gates merge.
5. After merge, **manual bootstrap** (out of cluster):
   ```sh
   kubectl apply -f kubernetes/flux-config/registry/git/gitrepository.yaml
   kubectl apply -f kubernetes/ks.yaml   # root Kustomization with new path/sourceRef
   kubectl annotate gitrepository/home-ops -n flux-system \
     reconcile.fluxcd.io/requestedAt="$(date +%s)"
   ```
6. Verify (see Rollback & Verification below).

## Error handling / rollback

- **Path typo:** `flux get kustomizations -A | grep -v True` surfaces the offender. Fix the ks.yaml, push; Receiver reconciles.
- **GitRepository fails to clone:** Cluster stalls. Rollback by `kubectl apply -f kubernetes/flux-config/registry/oci/ocirepository.yaml` (already present), reverting the affected ks.yaml to use OCIRepository and the old `./<ns>/...` paths. Direct `kubectl apply -f` for the rollback commit (or push via a personal access token), then `flux reconcile source oci home-ops`.
- **Receiver webhook misfires / Misses:** `flux reconcile kustomization cluster -n flux-system` triggers a manual reconcile. The 10m GitRepository interval guarantees convergence in the worst case.

## Verification

Static (pre-merge):

- `pre-commit run --all-files` — gitleaks + trufflehog + flate-test.
- `kustomize build kubernetes/flux-config | kubeconform -strict -ignore-missing-schemas ...`
- `kustomize build kubernetes | kubeconform -strict -ignore-missing-schemas ...`

Cluster (post-merge, manual bootstrap):

- `flux get sources git -n flux-system` — `home-ops` Ready=True, artifact revision matches `main`.
- `flux get kustomizations -n flux-system` — `flux-registries`, `flux-system`, `flux-sops` Ready=True.
- `flux get kustomizations -A` — every consumer Ready=True.
- `kubectl get ocirepository -n flux-system home-ops` — still present, dormant.
- Sample app: `flux get helmreleases -n downloads sonarr-hd` — Ready=True; chart version unchanged.
- Webhook smoke test: `curl -X POST https://flux.whoverse.nexus/hook/087b90ea9fa7e2f177a1bbbcfb139032d8f373c7fc5586f3f355b3a99ee28a39 -H 'Content-Type: application/json' -d '{"action":"push","repository":"home-ops"}'` and observe a `Last Applied` bump on `Kustomization/cluster`.

## Out-of-scope (follow-up PR)

- `AGENTS.md` updates (lines 28, 101, 118-120, 138-141).
- `.agents/skills/home-ops-add-new-app/SKILL.md` template (`kind: OCIRepository` → `GitRepository` at L37; path note at L113; OCI build note at L104).
- `kubernetes-oci.yml` deletion (after one or two release cycles of confirming it isn't needed for rollback).
- Optional future: GitHub App `provider: github` authentication for higher GitHub rate-limit headroom.
