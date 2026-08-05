---
name: home-ops-add-new-app
description: Use when adding a new application to the home-ops Kubernetes GitOps repository - creates directory structure, ks.yaml, ocirepository.yaml, helmrelease.yaml, externalsecret.yaml, httproute.yaml, and kustomization.yaml for a new app
---

# Adding a New App to home-ops

## When to use

When deploying a new application to the Kubernetes cluster managed by Flux CD. Each app lives under `kubernetes/{namespace}/{component}/`.

## Step 1: Create directory structure

```bash
mkdir -p kubernetes/{namespace}/{component}/app
```

Where:
- `{namespace}` = Kubernetes namespace (e.g. `downloads`, `entertainment`, `default`)
- `{component}` = app name (e.g. `sonarr-hd`, `plex`)

If the namespace doesn't exist yet, also create `ns.yaml` and `kustomization.yaml` at the namespace level (see existing namespaces for pattern), and add the namespace to the top-level `kubernetes/kustomization.yaml` aggregator.

## Step 2: Create `ks.yaml` (Flux Kustomization)

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: {component}
  namespace: {namespace}
spec:
  targetNamespace: {namespace}
  components:
    - ../../../components/kopiur/backup   # only if the app has persistent data (PVCs)
  interval: 30m
  path: "./kubernetes/{namespace}/{component}/app"
  postBuild:
    substitute:
      APP: {component}
  sourceRef:
    kind: GitRepository
    name: home-ops
    namespace: flux-system
  timeout: 10m
  wait: true
  prune: true
```

- `components: ../../../components/kopiur/backup` wires the kopiur `Restore` populator + snapshot policy into the app's PVCs (backup-enabled apps only — skip for infra/storage components; compare with a similar existing app).
- `postBuild.substitute: APP: {component}` — the kopiur component files use the `${APP}` placeholder, so the **component name must match the PVC/HelmRelease name** for the restore to line up.

Then reference this in the namespace-level `kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ns.yaml
  - {component}/ks.yaml
```

## Step 3: Create `app/ocirepository.yaml` (chart source)

Apps pull the bjw-s app-template chart as an OCI artifact with cosign verification (see `home-ops-app-pattern`):

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: OCIRepository
metadata:
  name: {component}
  namespace: {namespace}
spec:
  interval: 1h
  layerSelector:
    mediaType: application/vnd.cncf.helm.chart.content.v1.tar+gzip
    operation: copy
  ref:
    tag: "5.0.1"        # pin explicitly (Renovate manages)
    digest: sha256:...
  url: oci://ghcr.io/bjw-s-labs/helm/app-template
  verify:
    provider: cosign
    matchOIDCIdentity:
      - issuer: ^https://token.actions.githubusercontent.com$
        subject: ^https://github.com/bjw-s-labs/helm-charts/.github/workflows/chart-release-steps.yaml@.*$
```

## Step 4: Create `app/helmrelease.yaml`

`helm.toolkit.fluxcd.io/v2` with `chartRef` pointing at the OCIRepository, values per `home-ops-app-pattern`.

## Step 5: Optional resource files

- `app/externalsecret.yaml` — for secrets (see `home-ops-external-secrets`)
- `app/httproute.yaml` — for ingress (see `home-ops-create-httproute`)
- `app/config/` — extra ConfigMaps/Secrets
- `app/snapshotpolicy.yaml` / `app/restore.yaml` — only if not using the `kopiur/backup` component (default path is the component)

## Step 6: Create `app/kustomization.yaml`

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - helmrelease.yaml
  - ocirepository.yaml
  # add externalsecret.yaml, httproute.yaml as needed
```

## Step 7: Deploy

```bash
# Local validation (matches pre-commit gate)
just flate-test --allow-missing-secrets

# Direct apply for quick iteration
kubectl apply -k kubernetes/{namespace}/{component}/app

# Production: commit + push
git add kubernetes/{namespace}/{component}
git commit -m "Add {component} to {namespace}"
git push
# Flux picks up automatically (poll interval); `just git-deploy` to force reconcile
```

## Common gotchas

- **`metadata.namespace` in `ks.yaml` MUST match the parent namespace directory** (enforced by pre-commit hook)
- The namespace's `kustomization.yaml` must reference `ns.yaml` **first** (enforced)
- `helmrelease.yaml` uses `helm.toolkit.fluxcd.io/v2` + `chartRef` (OCI) — not `chart.spec` with a HelmRepository
- **`spec.path`** is a 2-level path from repo root: `./kubernetes/{namespace}/{component}/app`
- If the app has PVCs and uses the `kopiur/backup` component, `metadata.name` of the HelmRelease/PVC must equal the `APP` substitute value
- Run `just flate-test` after creating files; the pre-commit hook enforces the structure rules on commit
