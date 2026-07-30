# OCIRepository → GitRepository Migration Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the Flux `OCIRepository/home-ops` source with a `GitRepository/home-ops` source so the cluster reconciles the GitHub repository directly, removing the OCI artifact build step from the day-2 loop.

**Architecture:** A new `GitRepository/home-ops` (HTTPS, branch=main, anonymous) is added under `kubernetes/flux-config/registry/git/`. All 68 Flux `Kustomization`s switch their `sourceRef.kind` from `OCIRepository` to `GitRepository` and gain a `./kubernetes` prefix on `spec.path` to match the new repo-root source. The Receiver is retargeted to the GitRepository, the Alert gains a parallel `GitRepository` event source, and the OCI GitHub workflow is suspended. The original OCIRepository manifest stays in tree as a rollback target. Cutover is single-commit + manual bootstrap of the GitRepository and the root Kustomization only; the rest self-reconciles.

**Tech Stack:** Flux CD v2 (`source.toolkit.fluxcd.io/v1` GitRepository + Kustomization), Kustomize, kubeconform, GitHub Actions, Just, kubectl/flux CLI.

---

## Task 1: Add `GitRepository/home-ops` manifest

**Files:**
- Create: `kubernetes/flux-config/registry/git/gitrepository.yaml`

- [ ] **Step 1: Create the new manifest**

Write `kubernetes/flux-config/registry/git/gitrepository.yaml` with:

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

The file MUST live alongside the existing (empty) `kubernetes/flux-config/registry/git/kustomization.yaml` so the aggregator at `kubernetes/flux-config/registry/kustomization.yaml:8` picks it up. Do **not** modify the aggregator.

- [ ] **Step 2: Verify aggregator inclusion**

Run:

```bash
kustomize build kubernetes/flux-config/registry
```

Expected: rendered YAML contains one `GitRepository/home-ops` document in the `flux-system` namespace, plus the existing `HelmRepository/openebs` and `HelmRepository/rook-ceph` and the dormant `OCIRepository/home-ops`.

- [ ] **Step 3: Commit**

```bash
git add kubernetes/flux-config/registry/git/gitrepository.yaml
git commit -m "feat(flux): add GitRepository/home-ops source manifest"
```

---

## Task 2: Update root `Kustomization/cluster`

**Files:**
- Modify: `kubernetes/ks.yaml`

- [ ] **Step 1: Edit the manifest**

In `kubernetes/ks.yaml` make two changes:

- `spec.path`: change `./` to `./kubernetes`.
- `spec.sourceRef.kind`: change `OCIRepository` to `GitRepository`.

`sourceRef.name: home-ops` and (if present) `sourceRef.namespace: flux-system` stay as-is.

Resulting file content:

```yaml
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: cluster
  namespace: flux-system
spec:
  dependsOn:
    - name: flux-system
  interval: 10m
  kubeconfig: { }
  path: ./kubernetes
  prune: true
  sourceRef:
    kind: GitRepository
    name: home-ops
  timeout: 15m
  wait: true
```

(Adjust the file to match the existing structure; only the two lines above change.)

- [ ] **Step 2: Validate**

Run:

```bash
kustomize build kubernetes | kubeconform -strict -ignore-missing-schemas \
  -schema-location default \
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
```

Expected: PASS. The root `Kustomization/cluster` should render with `path: ./kubernetes`.

- [ ] **Step 3: Commit**

```bash
git add kubernetes/ks.yaml
git commit -m "feat(flux): switch root Kustomization to GitRepository with ./kubernetes path"
```

---

## Task 3: Update the three flux-config Kustomizations

**Files:**
- Modify: `kubernetes/flux-config/flux-system.yaml`
- Modify: `kubernetes/flux-config/registries.yaml`
- Modify: `kubernetes/flux-config/sops/ks.yaml`

- [ ] **Step 1: Edit `flux-system.yaml`**

In `kubernetes/flux-config/flux-system.yaml`:

- `spec.path`: `./flux-config` → `./kubernetes/flux-config`.
- `spec.sourceRef.kind`: `OCIRepository` → `GitRepository`.

- [ ] **Step 2: Edit `registries.yaml`**

In `kubernetes/flux-config/registries.yaml`:

- `spec.path`: `./flux-config/registry` → `./kubernetes/flux-config/registry`.
- `spec.sourceRef.kind`: `OCIRepository` → `GitRepository`.

- [ ] **Step 3: Edit `flux-config/sops/ks.yaml`**

In `kubernetes/flux-config/sops/ks.yaml`:

- `spec.path`: `./flux-config/sops` → `./kubernetes/flux-config/sops`.
- `spec.sourceRef.kind`: `OCIRepository` → `GitRepository`.

- [ ] **Step 4: Validate**

Run:

```bash
kustomize build kubernetes/flux-config | kubeconform -strict -ignore-missing-schemas \
  -schema-location default \
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
```

Expected: PASS; rendered YAML for `Kustomization/flux-system`, `Kustomization/flux-registries`, `Kustomization/flux-sops` shows the new paths and `sourceRef.kind: GitRepository`.

- [ ] **Step 5: Commit**

```bash
git add kubernetes/flux-config/flux-system.yaml \
        kubernetes/flux-config/registries.yaml \
        kubernetes/flux-config/sops/ks.yaml
git commit -m "feat(flux): switch flux-config Kustomizations to GitRepository"
```

---

## Task 4: Bulk-update all component `ks.yaml` files

**Files:** Modify every file matching `kubernetes/**/ks.yaml` that was not touched in Tasks 1–3. **Actual count discovered during implementation: 62 files, 76 Kustomizations** (the plan/spec estimated 64/67 — actual is 62 component files because `kubernetes/ks.yaml` was already migrated in Task 2 and three flux-config files were already migrated in Task 3; component Kustomizations run higher than estimated because the repo has grown since the plan was authored).

- [ ] **Step 1: Discover the file set**

Run from repo root:

```bash
grep -rln "sourceRef:" kubernetes --include="ks.yaml" \
  | grep -v '^kubernetes/flux-config/'
```

Expected: 64 file paths (component `ks.yaml` files, excluding the three flux-config ones already updated).

- [ ] **Step 2: Apply the two edits to every file**

For each path returned in Step 1, apply exactly two sed replacements (GNU sed semantics, in-place, with backup). **NOTE: the plan's original simple sed was not idempotent for unquoted paths.** Use the **guarded** form below, which skips already-prefixed lines:

```bash
COMPONENT_KS_FILES=$(grep -rln "sourceRef:" kubernetes --include="ks.yaml" \
  | grep -v '^kubernetes/flux-config/')

echo "$COMPONENT_KS_FILES" | while read -r f; do
  sed -i \
    -e 's|kind: OCIRepository|kind: GitRepository|g' \
    -e '/^  path: \.\/kubernetes\//!s|^  path: \./|  path: \./kubernetes/|g' \
    "$f"
done
```

Notes:
- The `kind: OCIRepository` substitution matches every manifest with that string (component ks.yaml files reference only `OCIRepository/home-ops` because the 50 upstream chart OCI repositories are not referenced as `sourceRef` — they live in `HelmRelease.spec.chartRef`). Verify before running: `grep -l "kind: OCIRepository" $COMPONENT_KS_FILES` must return all intended files and ONLY those files.
- The `path:` substitution uses a guard (`/^  path: \.\/kubernetes\//!`) so a re-run does NOT double-prefix already-prefixed unquoted paths. (Quoted paths like `"./foo/bar"` are self-protecting because the regex anchor `path: "./` won't match `path: "./kubernetes/...` — but the guard makes the unquoted case safe too.)
- The substitution covers BOTH quoted (`"./..."`) and unquoted (`./...`) path styles (the unquoted form is rare — only 6 of 76 Kustomizations).
- Component paths do not include the upstream chart OCIRepository references because HelmRelease `chartRef.kind` lives in `app/ocirepository.yaml`, not in `ks.yaml`.

- [ ] **Step 3: Sanity-check the substitution**

Run:

```bash
grep -rEn "^  sourceRef:" kubernetes --include="ks.yaml" \
  | grep -v "kind: GitRepository" \
  | grep -v "kind: OCIRepository"
```

Expected: empty output (every `sourceRef.kind` is now `GitRepository` or `OCIRepository`; nothing left to fix).

Run:

```bash
grep -rEn "^  path: \./" kubernetes --include="ks.yaml" \
  | grep -v "^  path: \./kubernetes/"
```

Expected: empty output (every `spec.path` is now prefixed with `./kubernetes/`).

Finally, count the changes to confirm:

```bash
git diff --stat | grep ks.yaml
```

Expected: 64 files changed; insertions + deletions roughly proportionate to the number of `kind:`/`path:` lines per file.

- [ ] **Step 4: Validate**

Run:

```bash
kustomize build kubernetes | kubeconform -strict -ignore-missing-schemas \
  -schema-location default \
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
```

Expected: PASS. Every rendered `Kustomization` must show `spec.path` beginning with `./kubernetes/` and `spec.sourceRef.kind: GitRepository`.

- [ ] **Step 5: Run pre-commit**

```bash
pre-commit run --all-files
```

Expected: PASS for gitleaks, trufflehog, and flate-test. If flate-test reports failures, inspect the specific files (likely a path-resolution issue) and re-run after correction.

- [ ] **Step 6: Commit**

```bash
git add -A kubernetes
git commit -m "feat(flux): switch component Kustomizations to GitRepository with ./kubernetes paths"
```

---

## Task 5: Update `Receiver` for the GitRepository

**Files:**
- Modify: `kubernetes/flux-system/webhook/app/webhook-receiver.yaml`

- [ ] **Step 1: Edit the manifest**

In `kubernetes/flux-system/webhook/app/webhook-receiver.yaml`, change the `spec.resources[0]` entry:

- `kind: OCIRepository` → `kind: GitRepository`.

The full `spec.resources[0]` after the edit:

```yaml
- apiVersion: source.toolkit.fluxcd.io/v1
  kind: GitRepository
  name: home-ops
  namespace: flux-system
```

`name` and `namespace` are unchanged. The Receiver triggers on `home-ops` only; no other resource is added.

- [ ] **Step 2: Validate**

Run:

```bash
kustomize build kubernetes/flux-system/webhook/app | kubeconform -strict -ignore-missing-schemas \
  -schema-location default \
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
```

Expected: PASS; the rendered Receiver shows `kind: GitRepository` in `spec.resources[0]`.

- [ ] **Step 3: Commit**

```bash
git add kubernetes/flux-system/webhook/app/webhook-receiver.yaml
git commit -m "feat(flux): retarget webhook Receiver to GitRepository/home-ops"
```

---

## Task 6: Update `Alert` event sources

**Files:**
- Modify: `kubernetes/flux-system/webhook/app/webhook-alert.yaml`

- [ ] **Step 1: Add a parallel `eventSources` entry**

In `kubernetes/flux-system/webhook/app/webhook-alert.yaml`, find the `spec.eventSources` block (currently a single list containing `- kind: OCIRepository / name: '*' / namespace: flux-system`). Append a second entry below it:

```yaml
        - kind: GitRepository
          name: '*'
          namespace: flux-system
```

The existing OCIRepository entry stays (50 upstream chart OCIRepositories still fire events). Match the indentation in the file exactly.

Resulting `spec.eventSources`:

```yaml
  eventSources:
    - kind: OCIRepository
      name: '*'
      namespace: flux-system
    - kind: GitRepository
      name: '*'
      namespace: flux-system
```

- [ ] **Step 2: Validate**

Run:

```bash
kustomize build kubernetes/flux-system/webhook/app | kubeconform -strict -ignore-missing-schemas \
  -schema-location default \
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
```

Expected: PASS; rendered Alert has two `eventSources` entries (one OCIRepository wildcard, one GitRepository wildcard).

- [ ] **Step 3: Commit**

```bash
git add kubernetes/flux-system/webhook/app/webhook-alert.yaml
git commit -m "feat(flux): add GitRepository wildcard to webhook alert event sources"
```

---

## Task 7: Update Justfile

**Files:**
- Modify: `Justfile`

- [ ] **Step 1: Add the Git source variable**

Find the existing block near the top of `Justfile` (currently lines 8–10):

```just
registry := "ghcr.io/alinanova21"
repo_name := "home-ops"
oci_url := registry + "/" + repo_name
```

Append a parallel line:

```just
git_url := "https://github.com/AlinaNova21/home-ops"
```

- [ ] **Step 2: Add `git-flux-sync` recipe**

Locate the existing `flux-sync` recipe (lines ~110–113). Add a sibling recipe after it:

```just
git-flux-sync:
    @kubectl annotate --overwrite gitrepository/home-ops -n flux-system \
        reconcile.fluxcd.io/requestedAt="$(date +%s)" || true
    @flux reconcile kustomization cluster -n flux-system || true
```

Match the indentation style used by `flux-sync`. Note the JGC/justfile recipe format may differ (some recipes use spaces vs tabs) — replicate the existing style.

- [ ] **Step 3: Add `git-deploy` recipe**

Add a sibling to the existing `deploy` recipe:

```just
git-deploy: git-flux-sync
```

(Body delegates entirely to the new sync recipe; Flux will reconcile both the GitRepository and the cluster kustomization.)

- [ ] **Step 4: Extend `flux-status` to include GitRepositories**

In the existing `flux-status` recipe (lines ~115–124), find the line that lists OCIRepositories and add a parallel call for GitRepositories. For example, change:

```just
flux-status:
    @kubectl get pods -n flux-system
    @echo "--- OCIRepositories ---"
    @kubectl get ocirepositories -n flux-system
    @echo "--- HelmReleases ---"
    @kubectl get helmreleases -A
```

to:

```just
flux-status:
    @kubectl get pods -n flux-system
    @echo "--- OCIRepositories (upstream chart pulls + dormant home-ops) ---"
    @kubectl get ocirepositories -n flux-system
    @echo "--- GitRepositories ---"
    @kubectl get gitrepositories -n flux-system
    @echo "--- HelmReleases ---"
    @kubectl get helmreleases -A
```

Adjust wording to match the existing comment style.

- [ ] **Step 5: Extend `destroy-flux` to include GitRepositories**

In the existing `destroy-flux` recipe, find the `kubectl delete ocirepositories --all -n flux-system` line and add a parallel deletion:

```just
destroy-flux:
    @kubectl delete helmreleases --all -n flux-system
    @kubectl delete kustomizations --all -n flux-system
    @kubectl delete ocirepositories --all -n flux-system
    @kubectl delete gitrepositories --all -n flux-system
    @kubectl delete helmrepositories --all -n flux-system
```

(Adjust lines to match the existing recipe; the only addition is the `gitrepositories` line.)

- [ ] **Step 6: Validate**

Run:

```bash
just --list
```

Expected: new recipes `git-flux-sync` and `git-deploy` appear in the recipe list (alongside the dormant OCI recipes).

Run a dry parse:

```bash
just --evaluate
```

Expected: zero errors.

- [ ] **Step 7: Commit**

```bash
git add Justfile
git commit -m "feat(just): add Git-flavored flux recipes; extend status/destroy helpers"
```

---

## Task 8: Suspend `.github/workflows/kubernetes-oci.yml`

**Files:**
- Modify: `.github/workflows/kubernetes-oci.yml`

- [ ] **Step 1: Replace triggers with `workflow_dispatch` only**

Find the `on:` block at the top of the file. Replace the existing push and `workflow_dispatch` triggers with a workflow_dispatch-only entry:

```yaml
on:
  workflow_dispatch:
```

(If the existing file uses `on.push` with `paths:` filter or `branches:` filter, all of those entries are removed; only `workflow_dispatch` remains.)

- [ ] **Step 2: Gate the build job with `if: false`**

In the `jobs:` block, add an `if: ${{ false }}` condition to the only job, so manual `workflow_dispatch` triggers do nothing:

```yaml
jobs:
  build:
    if: ${{ false }}
    runs-on: ubuntu-latest
    ...
```

Indent under `jobs:` matches existing structure.

- [ ] **Step 3: Validate`

Run:

```bash
actionlint .github/workflows/kubernetes-oci.yml 2>/dev/null \
  || python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/kubernetes-oci.yml'))"
```

Expected: YAML parses without errors. (actionlint may not be installed locally; the `python3` fallback is sufficient.)

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/kubernetes-oci.yml
git commit -m "ci(oci): suspend kubernetes-oci workflow (kept as dormant rollback artifact)"
```

---

## Task 9: Full-tree static validation + CI gate

**Files:** none (validation only).

- [ ] **Step 1: Run `pre-commit` end-to-end**

```bash
pre-commit run --all-files
```

Expected: all hooks pass (gitleaks, trufflehog, flate-test). If any hook fails, fix the offending file before continuing.

- [ ] **Step 2: Validate `kubernetes/flux-config`**

```bash
kustomize build kubernetes/flux-config | kubeconform -strict -ignore-missing-schemas \
  -schema-location default \
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
```

Expected: PASS.

- [ ] **Step 3: Validate `kubernetes/` (top-level aggregator)**

```bash
kustomize build kubernetes | kubeconform -strict -ignore-missing-schemas \
  -schema-location default \
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
```

Expected: PASS.

- [ ] **Step 4: Sanity-check that no `OCIRepository/home-ops` consumers remain**

```bash
grep -rEn "name: home-ops" kubernetes --include="*.yaml" \
  | grep -B1 "name: home-ops" \
  | head -50
```

Expected: every line referencing `name: home-ops` is paired with either `kind: GitRepository` (in `gitrepository.yaml`, `ks.yaml`, `flux-system.yaml`, `registries.yaml`, `sops/ks.yaml`, component `ks.yaml` files, `webhook-receiver.yaml`, `webhook-alert.yaml`) or is the dormant `OCIRepository/home-ops` in `kubernetes/flux-config/registry/oci/ocirepository.yaml` and a single Annotation-style reference inside the Justfile recipe (which is a comment-free annotation, not a manifest). No live `Kustomization` references `OCIRepository/home-ops`.

- [ ] **Step 5: Push the branch and confirm CI**

```bash
git push -u origin feat/gitrepository-migration
gh pr create --fill --base main
```

Expected: PR opens with the title generated from the commit subject. CI (`validate-kubernetes.yml`) runs and passes.

- [ ] **Step 6: Merge the PR**

Once CI is green:

```bash
gh pr merge --squash --delete-branch
```

Or the standard merge flow the team uses (squash vs rebase vs merge commit). After merge, do **not** reconcile from this session — that's the manual bootstrap step (Task 10).

---

## Task 10: Manual cluster bootstrap + verification

**Files:** none (cluster operations only). To be run from a workstation with `kubectl` and `flux` CLIs pointed at the home-ops cluster.

- [ ] **Step 1: Confirm GitRepository is reachable**

```bash
flux get sources git -n flux-system 2>&1 | head -5 || true
kubectl get crd gitrepositories.source.toolkit.fluxcd.io >/dev/null 2>&1 \
  || kubectl get crd sources.toolkit.fluxcd.io >/dev/null 2>&1
```

Expected: the CRD exists (no output, exit 0). The `flux get sources git` command may error because the GitRepository is not yet applied — that is expected and safe to retry after Step 2.

- [ ] **Step 2: Apply the GitRepository manifest**

```bash
kubectl apply -f kubernetes/flux-config/registry/git/gitrepository.yaml
```

Expected:

```
gitrepository.source.toolkit.fluxcd.io/home-ops created
```

- [ ] **Step 3: Apply the root Kustomization (new path + sourceRef)**

```bash
kubectl apply -f kubernetes/ks.yaml
```

Expected:

```
kustomization.kustomize.toolkit.fluxcd.io/cluster configured
```

(`configured`, not `created`, because Flux already tracks `Kustomization/cluster`.)

- [ ] **Step 4: Annotate the GitRepository to force an immediate reconcile**

```bash
kubectl annotate --overwrite gitrepository/home-ops -n flux-system \
  reconcile.fluxcd.io/requestedAt="$(date +%s)"
```

Expected:

```
gitrepository.source.toolkit.fluxcd.io/home-ops annotated
```

- [ ] **Step 5: Wait for the GitRepository to become Ready**

```bash
kubectl wait --for=condition=ready \
  gitrepository/home-ops -n flux-system --timeout=120s
```

Expected: `gitrepository.source.toolkit.fluxcd.io/home-ops condition met`. If it times out, run `kubectl describe gitrepository/home-ops -n flux-system` to inspect (most common cause: GitHub anonymous rate-limit — wait 60s and retry, or apply a manual `flux reconcile source git home-ops`).

- [ ] **Step 6: Wait for the cluster Kustomization to become Ready**

```bash
kubectl wait --for=condition=ready \
  kustomization/cluster -n flux-system --timeout=300s
```

Expected: `kustomization.kustomize.toolkit.fluxcd.io/cluster condition met`. If it times out, run `kubectl describe kustomization/cluster -n flux-system` to surface which child Kustomization failed (likely a path typo from Task 4).

- [ ] **Step 7: Verify flux-system namespace Kustomizations**

```bash
flux get kustomizations -n flux-system
```

Expected: `cluster`, `flux-registries`, `flux-sops`, `flux-system` all Ready=True.

- [ ] **Step 8: Verify the entire cluster**

```bash
flux get kustomizations -A | tee /tmp/ks-status.txt
grep -v " True " /tmp/ks-status.txt || echo "ALL READY"
```

Expected: every Kustomization is Ready=True; the grep finds nothing and prints `ALL READY`. If any Kustomization is False, inspect with `flux get kustomizations -A --no-header | grep -v True` to find the offender and check its `spec.path` (most likely a Task-4 substitution gap).

- [ ] **Step 9: Sample app smoke test**

```bash
flux get helmreleases -n downloads sonarr-hd
kubectl get pods -n downloads -l app.kubernetes.io/name=sonarr-hd
```

Expected: HelmRelease Ready=True; pods Running. The chart version must be unchanged from before the migration.

- [ ] **Step 10: Webhook smoke test**

```bash
curl -sS -X POST \
  https://flux.whoverse.nexus/hook/087b90ea9fa7e2f177a1bbbcfb139032d8f373c7fc5586f3f355b3a99ee28a39 \
  -H 'Content-Type: application/json' \
  -H 'X-GitHub-Event: push' \
  -d '{"action":"push","repository":"home-ops"}'
```

Expected: HTTP 204/200 with an empty body. Within 30s of this call, `kubectl get kustomization cluster -n flux-system -o jsonpath='{.status.lastHandledReconcileAt}'` should bump (the webhook is HMAC-signed by GitHub Actions in production; a manual curl returns HTTP 200 but Flux may reject HMAC — in that case verify by `kubectl describe receiver -n flux-system` and rely on the 10m poll interval).

- [ ] **Step 11: Confirm the dormant OCIRepository is present**

```bash
kubectl get ocirepository -n flux-system home-ops
```

Expected: present, with no recent reconcile events. This is the rollback target; do not delete it.

- [ ] **Step 12: Final report**

Open an issue or PR description noting the cutover result: ✓ root + 67 children reconciled, ✓ sample app rolled, ✓ webhook live, ✓ OCIRepository/home-ops retained as dormant.

---

## Self-Review

**Spec coverage:**

| Spec section | Task |
|---|---|
| Add `GitRepository/home-ops` | Task 1 |
| Root Kustomization update | Task 2 |
| Three flux-config Kustomizations | Task 3 |
| 64 component ks.yaml files | Task 4 |
| Receiver retarget | Task 5 |
| Alert parallel entry | Task 6 |
| Justfile recipes + vars | Task 7 |
| Suspend OCI GitHub Action | Task 8 |
| Static validation | Task 9 |
| Manual bootstrap + cluster verification | Task 10 |

All decisions, files, commands, and gates from the spec (`docs/superpowers/specs/2026-07-29-gitrepository-migration-design.md`) are covered.

**Placeholder scan:** No TBDs, TODOs, or "fill in details" markers. Every code-bearing step provides concrete file content.

**Type/name consistency:** `GitRepository/home-ops`, `Kustomization/cluster`, `Receiver/oci-webhook-receiver`, `Alert/oci-webhook-alert`, `Kustomization/flux-registries`, `Kustomization/flux-sops`, `Kustomization/flux-system` referenced identically across tasks. Namespace `flux-system` is consistent. Secret refs (`sops-age`, `webhook-token`) untouched. The Justfile recipes `git-flux-sync`/`git-deploy` referenced as written in Task 7 and dispatched in Task 10.

**Idempotency note:** Task 4's sed-based bulk substitution is idempotent for a second run (it would replace `kind: OCIRepository` with `kind: GitRepository` again, no-op; and prepend `./kubernetes/` only to lines starting with `path: ./` — already-prefixed lines are not affected because the regex anchored after `path: ./` won't double-match `path: ./kubernetes/...`). The plan does NOT require a re-run; if one is needed, a fresh run from `main` is preferable.
