# Return miroir to official images (0.11.19)

- **Date:** 2026-08-04
- **Status:** Draft, pending user review
- **Owner:** home-ops maintainers

## 1. Problem

Commit `f1fc8d1` (2026-08-01) pointed the miroir controller/agent/gateway
images at custom local builds `zot.whoverse.dev/miroir-*:0.11.15-restoretopology`
(miroir 0.11.15 + a local "restoretopology" patch). The patch fixed a
shrink-restore failure: restoring a replicated snapshot into a class with
fewer diskful replicas stranded the PVC in `ProvisioningFailed`, because the
scheduler cannot see snapshot-leg placement and re-picked a legless node on
every retry. This is exercised by the kopiur restore path
(`kubernetes/components/kopiur/backup/restore.yaml`).

The `helmrelease.yaml` values override:

```yaml
image:
  repository: zot.whoverse.dev/miroir-controller
  tag: 0.11.15-restoretopology
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

## 2. Goal

Return miroir to official `ghcr.io/home-operations/miroir-*` images now that
the restoretopology fix is merged upstream, keeping the fix's behavior in
production.

Upstream resolution: PR `home-operations/miroir#407`
`fix(csi): relocate a shrink-restore off a legless scheduler selection`,
merged 2026-08-04 and released in **0.11.19** (diagnosed and reproduced by
@AlinaNova21). The official chart 0.11.19 ships `appVersion: 0.11.19` and
defaults `image.repository` to `ghcr.io/home-operations/miroir-controller`,
`agent.image.repository` to `ghcr.io/home-operations/miroir-agent`, both with
`tag: ""` (resolves to appVersion). The gateway is disabled by default, so the
`gateway.image` override is inert today.

### In scope

- `kubernetes/storage/miroir/app/helmrelease.yaml`: delete the custom image
  override block (controller/agent/gateway) so chart defaults resolve to the
  official images at 0.11.19.
- `kubernetes/storage/miroir/app/ocirepository.yaml`: bump chart ref from
  0.11.18 to 0.11.19, updating the pinned digest (cosign verification
  unchanged).

### Out of scope

- Zot registry itself and the stale custom miroir images it holds (inert;
  no in-repo change).
- Renovate package rules (the `/^ghcr\.io\/home-operations\//` auto-merge
  minor/digest rule will start matching miroir images; decided separately).
- Any miroir `config/` resources (nodegroup, storage classes, snapshot
  classes are image-agnostic).

## 3. Target state

- `ocirepository.yaml`:
  ```yaml
  ref:
    tag: 0.11.19
    digest: sha256:13277f39079c66e96b858ac76c894732e2d7f518f8c34df3832f79e87c5adcbf
  ```
  (digest verified via `crane digest ghcr.io/home-operations/charts/miroir:0.11.19`)
- `helmrelease.yaml`: no `image:`, `agent.image:`, or `gateway.image:` values;
  controller and agent pods run `ghcr.io/home-operations/miroir-*:0.11.19`.
- Flux reconciliation green; `HelmRelease/miroir` healthy, upgrade `retries: 3`
  with `RetryOnFailure` already configured.

## 4. Verification

1. Worktree workflow: `just flate-test` baseline before changes, then
   `pre-commit run --all-files` + `just flate-test` after.
2. After Flux reconciles: controller Deployment and agent DaemonSet use
   `ghcr.io/home-operations/miroir-*:0.11.19`; `HelmRelease/miroir` shows
   `Ready` with the new revision.
3. Restore smoke test: exercise the shrink-restore path (kopiur restore or a
   manual PVC restore from `volumesnapshotclass`) to confirm upstream #407
   behaves in production.
4. Rollback: revert the commit or restore the image overrides; the custom
   images remain in zot.

## 5. Risks

- Upstream 0.11.19 differs from the custom `0.11.15-restoretopology` build
  (0.11.15 → 0.11.19 includes unrelated agent/controller fixes). If a
  regression appears, rollback is a one-commit revert.
- Renovate will begin tracking the semver image tags; the existing auto-merge
  rule for `ghcr.io/home-operations/*` would auto-merge minor/digest image
  updates. Flagged for a separate decision, not changed here.
