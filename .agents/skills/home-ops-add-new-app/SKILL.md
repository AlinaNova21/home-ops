---
name: home-ops-add-new-app
description: Use when adding a new application to the home-ops Kubernetes GitOps repository - creates directory structure, ks.yaml, helmrelease.yaml, externalsecret.yaml, httproute.yaml, and kustomization.yaml for a new app following the bjw-s app-template pattern
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

If the namespace doesn't exist yet, also create `ns.yaml` and `kustomization.yaml` at the namespace level (see existing namespaces for pattern).

## Step 2: Create `ks.yaml` (Flux Kustomization)

```yaml
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: {component}
  namespace: {namespace}
spec:
  interval: 15m
  path: "./{namespace}/{component}/app"
  sourceRef:
    kind: OCIRepository
    name: home-ops
    namespace: flux-system
  dependsOn:
    - name: {dependency}  # optional: e.g. {namespace}-database
  timeout: 10m
  wait: true
  prune: true
```

Then reference this in the namespace-level `kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ns.yaml
  - {component}/ks.yaml
```

And add the namespace to the top-level `kubernetes/kustomization.yaml` aggregator:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - {namespace}
  # ...other namespaces
```

## Step 3: Create resource files in `app/`

See `home-ops-app-pattern` for the bjw-s HelmRelease shape.

Optional files (create only if needed):
- `app/externalsecret.yaml` — for secrets (see `home-ops-external-secrets`)
- `app/httproute.yaml` — for ingress (see `home-ops-create-httproute`)
- `app/config/` — extra ConfigMaps/Secrets
- `app/repository/` — additional HelmRepository/OCIRepository sources

## Step 4: Create `app/kustomization.yaml`

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - helmrelease.yaml
  # add externalsecret.yaml, httproute.yaml as needed
```

## Step 5: Add to namespace-level kustomization

Edit `kubernetes/{namespace}/kustomization.yaml` and add the new component's `ks.yaml` reference.

## Step 6: Deploy

```bash
# Local validation (matches CI)
kustomize build kubernetes | kubeconform -strict -ignore-missing-schemas

# Direct apply for quick iteration
kubectl apply -k kubernetes/{namespace}/{component}/app

# Production: commit + push
git add kubernetes/{namespace}/{component}
git commit -m "Add {component} to {namespace}"
git push
# OCI artifact auto-built; Flux picks up automatically
```

## Common gotchas

- **`metadata.namespace` in `ks.yaml` MUST match the parent namespace directory** (enforced by pre-commit hook)
- The namespace's `kustomization.yaml` must reference `ns.yaml` **first** (enforced)
- `bjw-s/app-template` chart structure — see `home-ops-app-pattern` skill
- App chart version: pin explicitly (don't use `latest`)
- Use `./{namespace}/{component}/app` for `spec.path` (3-level path from OCI artifact root)
