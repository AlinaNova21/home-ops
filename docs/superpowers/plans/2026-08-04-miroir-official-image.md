# Miroir → Official Images (0.11.19) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Return the miroir controller/agent images to official `ghcr.io/home-operations/miroir-*:0.11.19` and bump the chart OCIRepository to 0.11.19, keeping the upstream `restoretopology` fix (PR home-operations/miroir#407) in production.

**Architecture:** Two manifest edits in `kubernetes/storage/miroir/app/` — delete the custom zot image override block from `helmrelease.yaml` (chart defaults resolve to official images at appVersion 0.11.19) and bump the pinned chart tag+digest in `ocirepository.yaml`. Flux reconciles the change; controller/agent pods roll to the official images.

**Tech Stack:** Flux v2 (OCIRepository + HelmRelease, cosign-verified), home-operations/miroir chart 0.11.19, flate, pre-commit (gitleaks/trufflehog).

**Spec reference:** `docs/superpowers/specs/2026-08-04-miroir-official-image-design.md`

**Validation matrix (run after every task):**

| Check | Command |
|---|---|
| Structural validation | `just flate-test` |
| Secrets scan | `pre-commit run --all-files` |
| Chart digest sanity | `crane digest ghcr.io/home-operations/charts/miroir:0.11.19` |

---

## File Structure

### Modified

- `kubernetes/storage/miroir/app/ocirepository.yaml` — chart ref 0.11.18 → 0.11.19 (+ digest)
- `kubernetes/storage/miroir/app/helmrelease.yaml` — remove `image` / `agent.image` / `gateway.image` overrides

### Untouched

- `kubernetes/storage/miroir/config/` — nodegroup, storage classes, snapshot classes (image-agnostic)
- `kubernetes/storage/zot/` — registry stays; stale miroir images left in place (inert)

---

## Task 1: Bump chart to 0.11.19

**Files:**
- Modify: `kubernetes/storage/miroir/app/ocirepository.yaml`

- [ ] **Step 1: Edit the ref block**

Change:

```yaml
  ref:
    tag: 0.11.18
    digest: sha256:1b0a12b85ac7a918577bb2f7e6fce789949a6c8742d617c529a533b1b0409cd8
```

to:

```yaml
  ref:
    tag: 0.11.19
    digest: sha256:13277f39079c66e96b858ac76c894732e2d7f518f8c34df3832f79e87c5adcbf
```

- [ ] **Step 2: Verify the digest matches upstream**

Run: `crane digest ghcr.io/home-operations/charts/miroir:0.11.19`
Expected: `sha256:13277f39079c66e96b858ac76c894732e2d7f518f8c34df3832f79e87c5adcbf`

- [ ] **Step 3: Validate**

Run: `just flate-test`
Expected: `✓ OCIRepository storage/miroir` passes, overall suite green.

---

## Task 2: Remove custom image overrides

**Files:**
- Modify: `kubernetes/storage/miroir/app/helmrelease.yaml`

- [ ] **Step 1: Delete the image override block**

Under `spec.values`, remove:

```yaml
    image:
      repository: zot.whoverse.dev/miroir-controller
      tag: 0.11.15-restoretopology
      # Chart-default digest must be cleared: digest wins over tag in the chart helpers.
      digest: ""
    agent:
      image:
        repository: zot.whoverse.dev/miroir-agent
        tag: 0.11.15-restoretopology
        digest: ""
    gateway:
      image:
        repository: zot.whoverse.dev/miroir-gateway
        tag: 0.11.15-restoretopology
        digest: ""
```

so the values block begins directly with:

```yaml
  values:
    drbd:
      resync:
        minRate: 10M
```

The chart defaults (`image.repository: ghcr.io/home-operations/miroir-controller`, `agent.image.repository: ghcr.io/home-operations/miroir-agent`, `tag: ""` → appVersion 0.11.19) take over. The `gateway.image` override was inert (gateway disabled by default).

- [ ] **Step 2: Validate**

Run: `just flate-test`
Expected: `✓ HelmRelease storage/miroir` passes with no new warnings (values match chart defaults).

---

## Task 3: Final validation

- [ ] **Step 1: Run full pre-commit**

Run: `pre-commit run --all-files`
Expected: gitleaks + trufflehog pass (no secrets in a version bump).

- [ ] **Step 2: Re-run flate**

Run: `just flate-test`
Expected: `✓ 185 passed` (same baseline, no new warnings).

- [ ] **Step 3: Diff review**

Run: `git diff --stat`
Expected: 2 files changed (ocirepository.yaml, helmrelease.yaml) + plan/spec docs.

---

## Task 4: Commit, push, PR

- [ ] **Step 1: Commit**

```bash
git add kubernetes/storage/miroir/app/ocirepository.yaml kubernetes/storage/miroir/app/helmrelease.yaml docs/superpowers/plans/2026-08-04-miroir-official-image.md
git commit -m "chore(miroir): return to official images 0.11.19

Drop the custom zot.whoverse.dev 0.11.15-restoretopology image overrides
now that upstream PR home-operations/miroir#407 (shrink-restore legless
selection) is released in 0.11.19. Bump the chart OCIRepository ref."
```

- [ ] **Step 2: Push**

```bash
git push origin feat/miroir-official-image
```

- [ ] **Step 3: Create PR**

```bash
gh pr create --fill
```

Expected: PR with 2-file manifest diff; CI (kustomize build + kubeconform) green.

- [ ] **Step 4: STOP — do not merge**

Merging requires an explicit user order (AGENTS.md explicit-orders gate).

---

## Task 5: Post-merge verification (cluster)

> Runs after the PR is merged and Flux reconciles. Requires `kubectl` access and is gated by an explicit user "merge it".

- [ ] **Step 1: Confirm release is healthy**

Run: `kubectl get helmrelease miroir -n storage`
Expected: `Ready=True`, latest revision (0.11.19).

- [ ] **Step 2: Confirm official images**

Run: `kubectl get deploy miroir-controller -n storage -o jsonpath='{.spec.template.spec.containers[*].image}'` and `kubectl get ds -n storage -o jsonpath='{range .items[*]}{.metadata.name}{": "}{.spec.template.spec.containers[*].image}{"\n"}{end}'`
Expected: `ghcr.io/home-operations/miroir-controller:0.11.19` and `ghcr.io/home-operations/miroir-agent:0.11.19` on all nodes.

- [ ] **Step 3: Restore smoke test**

Trigger a kopiur restore (or manual PVC restore from `volumesnapshotclass`) exercising the shrink-restore path.
Expected: PVC binds without `ProvisioningFailed`; no `ResourceExhausted ... no complete source snapshot leg exists on topology node` events.

- [ ] **Step 4: Rollback path (only if regression)**

Revert the PR commit or re-add the zot image overrides (custom images still in zot). `flux reconcile kustomization cluster -n flux-system` to apply.
