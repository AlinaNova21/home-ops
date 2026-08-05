---
name: home-ops-flate
description: Use flate to validate and diff Flux CD Kubernetes resources — the local validation gate (pre-commit + just recipes); CI still runs kustomize build + kubeconform
---

# flate — Flux Rendering and Diff Tool

`flate` renders and diffs Flux Kustomizations and HelmReleases using upstream SDKs. No `helm`, `kustomize`, or `flux` binaries required.

**Pinned in `mise.toml`**: `github:home-operations/flate`

## Commands

### `flate test all` — Validate structure

Validates every Kustomization, HelmRelease, and Flux source CR. Exits 0 on success. Does NOT require a live cluster.

```bash
flate test all -p kubernetes
```

Use `--namespace` to limit to a single namespace:
```bash
flate test all -p kubernetes --namespace default
```

Use `--allow-missing-secrets` to soft-skip Secret/ConfigMap refs that only materialize in the live cluster (e.g. ExternalSecret targets):
```bash
flate test all -p kubernetes --allow-missing-secrets
```

### `flate diff all` — Diff rendered output

Diff rendered Kustomizations and HelmReleases against a baseline revision. Outputs changes in human-readable format by default.

```bash
# Diff everything against main
flate diff all -p kubernetes --base main

# In a PR, --base auto-detects via merge-base with @{u} or origin/HEAD
flate diff all -p kubernetes
```

### `flate diff images` — Track image changes

List container images that changed between current tree and baseline:

```bash
flate diff images -p kubernetes --base main
```

### `flate get` — Inventory

```bash
flate get ks -p kubernetes       # list all Kustomizations
flate get hr -p kubernetes       # list all HelmReleases
flate get images -p kubernetes   # list all container images
```

## Key Flags

| Flag | Purpose |
|------|---------|
| `-p kubernetes` | Path to the Flux cluster directory |
| `--base main` | Baseline git rev for diff (branch name, SHA, `HEAD~N`) |
| `--namespace ns` | Limit to namespace |
| `--allow-missing-secrets` | Soft-skip Secret/ConfigMap refs that only exist in the live cluster |
| `--skip-schema-validation` | Skip Helm `values.schema.json` validation (skips allocation churn on large repos; only for `build`/`diff`) |
| `--output human\|github\|json\|yaml` | Output format |

## Known Limitations

- `flate build` requires live source fetches (OCI registries, Git repositories) and is not usable for local/offline validation. Use `flate test` instead for structural validation.
- `flate test` validates Kustomization/HelmRelease structure and source availability — it does NOT perform Helm `values.schema.json` validation (schema validation is only available in `build`/`diff` via `--skip-schema-validation`).

## Pre-commit Hook

The repo ships a `flate-test` hook in `.pre-commit-config.yaml` (also run via `just flate-test`):

```yaml
- id: flate-test
  name: Validate Flux resources (flate test)
  description: Validate all Kustomizations and HelmReleases
  entry: flate test all -p kubernetes
  language: system
  pass_filenames: false
  stages: [pre-commit]
  files: ^kubernetes/
```

Local usage via `just`:
```bash
just flate-test                     # basic validation
just flate-test --allow-missing-secrets
just flate-build                    # render all resources
```

Install pre-commit hooks:
```bash
mise run hooks:install
# or
pre-commit run --all-files
```
