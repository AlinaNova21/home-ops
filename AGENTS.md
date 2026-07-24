# AGENTS.md - home-ops Repository

Primary agent instructions for the home-ops repository. Covers Kubernetes infrastructure managed by Flux CD GitOps. For Talos Linux node configuration, see `talos/AGENTS.md`.

## Tooling

This repo's `mise.toml` pins only the **pre-commit stack** (`pre-commit`, `gitleaks`, `trufflehog`). User-level CLI tools (`kubectl`, `helm`, `helmfile`, `flux`, `cilium`, `k9s`, `sops`, `age`, `jq`, `yq`, `just`, `kustomize`, `kubeconform`) are managed outside the repo via `~/.config/mise/conf.d/`.

```bash
mise install                # installs pre-commit hook (auto-runs when .git exists)
mise run hooks:install      # idempotent reinstall of the hook
just hooks-install          # Justfile wrapper
pre-commit run --all-files  # run gitleaks + trufflehog across the working tree
```

Skip hooks:
```bash
SKIP=gitleaks,trufflehog git commit -m "..."
git commit --no-verify -m "..."
```

Tuning:
- gitleaks config: `.gitleaks.toml` (path-based allowlists, e.g. `charts/kasm/*.lock`)
- Allow inline: append `# gitleaks:allow` or `# trufflehog:ignore` on the matching line

## Architecture Overview

- **GitOps Engine**: Flux CD with OCI artifacts (auto-built by GitHub Actions on push to main)
- **Resource Composition**: Kustomize layering with Helm charts
- **Helm Charts**: bjw-s app-template for applications
- **Secrets**: External Secrets Operator syncing from 1Password Connect (`ClusterSecretStore: onepassword-connect`)
- **Ingress**: Envoy Gateway with Gateway API HTTPRoutes
  - External Gateway: Cloudflare Tunnel for public access (`*.whoverse.nexus`)
  - Internal Gateway: Tailscale VPN with HA for private access (`*.whoverse.dev`)
- **Networking**: Cilium CNI with BGP, Tailscale operator for VPN LoadBalancer
- **Storage**: `ceph-rbd` (primary), `openebs-hostpath` (fallback)

## Directory Structure

### Hierarchy

The Kubernetes directory follows a flat **Namespace → Component → Resources** hierarchy:

```
{namespace}/
├── ns.yaml              # Namespace definition (REQUIRED)
├── kustomization.yaml   # K8s Kustomization (references ns.yaml first)
└── {component}/
    ├── ks.yaml          # Flux Kustomization (metadata.namespace = namespace)
    └── app/             # Resources: helmrelease.yaml, externalsecret.yaml, etc.
```

- **namespace**: Kubernetes namespace (`downloads/`, `entertainment/`, `kube-system/`, etc.)
- **component**: Single deployed unit (`sonarr-hd/`, `plex/`, `cilium/`)
- **resources**: Actual K8s manifests (`helmrelease.yaml`, `externalsecret.yaml`, `httproute.yaml`, `config/`, `repository/`, `policies/`, etc.)

A single Flux `Kustomization/cluster` reconciles `./` (the whole `kubernetes/` tree). There is no `apps/` or `infrastructure/` group directory.

### File Types

| File | Type | Purpose |
|------|------|---------|
| `ns.yaml` | K8s Namespace | Defines the namespace (namespace-level only) |
| `ks.yaml` | Flux Kustomization | GitOps reconciliation |
| `kustomization.yaml` | K8s Kustomization | Resource composition |
| `kubernetes/kustomization.yaml` | K8s Kustomization | Top-level namespace aggregator (lists active namespaces) |

### Structure Rules (enforced by pre-commit hook)

1. `{namespace}/ns.yaml` must exist
2. `{namespace}/kustomization.yaml` must reference `ns.yaml` first
3. No `**/ns.yaml` outside namespace level (except `bootstrap/`)
4. Component `ks.yaml` `metadata.namespace` must match parent namespace directory

### Tree

```
kubernetes/
├── kustomization.yaml        # Top-level namespace aggregator
├── entertainment/            # jellyfin + storage (NFS PVCs)
├── default/                  # barcodebuddy, database, error-pages, grocy, mailpit, memos, speedtest-tracker
├── downloads/                # prowlarr, radarr-*, recyclarr, sabnzbd, seerr, sonarr-*, storage
├── sync/                     # seafile, storage
├── agent-sandbox-system/
├── auth/                     # dex-internal, dex-external, security-policies
├── cert-manager/
├── external-secrets-system/
├── flux-system/              # webhook receiver
├── headlamp/
├── inteldeviceplugins-system/
├── kopiur-system/            # Snapshot CRDs
├── kube-system/              # cilium, descheduler, gvisor, metrics-server, nfd, snapshot-controller
├── kyverno/                  # policies + rbac
├── monitoring/               # capacitor, grafana, vector, victoria-logs, victoria-metrics
├── network/                  # cloudflared, envoy-gateway, external-dns, pve-egress, tailscale
├── onepassword-connect/
├── spegel/                   # P2P image distribution
├── storage/                  # rook-ceph, openebs-localpv
├── system-upgrade/           # tuppr
├── components/               # Cross-cutting bundles (e.g. kopiur)
├── flux-config/              # Flux CD self-management (HelmRelease, OCIRepository, cluster root)
├── bootstrap/                # Cilium + Flux helmfile for first install
├── scripts/                  # deploy-infrastructure.sh
└── bootstrap.sh              # Initial Flux install (alternative to helmfile bootstrap)
```

## Deployment Workflow

### Production (GitOps)

```bash
# 1. Edit manifests
# 2. Commit + push
git add .
git commit -m "..."
git push

# 3. OCI artifact auto-built by .github/workflows/kubernetes-oci.yml
# 4. Flux picks up automatically (poll interval); force reconcile if needed:
flux reconcile source oci home-ops -n flux-system
flux reconcile kustomization cluster -n flux-system
```

### Development (Direct Apply)

```bash
kubectl apply -f path/to/resource.yaml
kubectl apply -k path/to/kustomization/
kubectl rollout restart deployment/<app> -n <namespace>

# NOTE: Direct applies are temporary - commit to git for persistence
```

### Justfile Recipes (Day-2)

| Recipe | Purpose |
|---|---|
| `just flux-status` | Pods, OCIRepositories, Kustomizations, HelmReleases |
| `just deploy` | `flux-push` + `flux-sync` (build OCI + reconcile) |
| `just flux-sync` | Annotate OCIRepository + reconcile cluster |
| `just flux-push` | Build OCI artifact locally and annotate OCIRepository |
| `just cilium-status` | `cilium status --wait` |
| `just destroy-flux` | Remove all Flux resources (keeps cluster) |

See `talos/AGENTS.md` for Talos recipes (`talos-gen`, `talos-apply`, `talos-bootstrap`, etc.).

## Validation

**CI** runs in `.github/workflows/validate-kubernetes.yml`: `kustomize build` + `kubeconform` against `kubernetes/flux-config` and `kubernetes/` (root aggregator).

**Local equivalent**:

```bash
# Install once (user-level via mise conf.d)
mise install

# Validate a directory
kustomize build kubernetes | kubeconform \
  -strict \
  -ignore-missing-schemas \
  -schema-location default \
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'

# Or the two top-level dirs in a loop
for dir in kubernetes/flux-config kubernetes; do
  echo "=== $dir ==="
  kustomize build "$dir" | kubeconform -strict -ignore-missing-schemas \
    -schema-location default \
    -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
done
```

## See Also

- `talos/AGENTS.md` — Talos cluster operations (talhelper, talsecret, Justfile recipes)
- Skills (in `.agents/skills/`):
  - `home-ops-add-new-app` — 6-step recipe for adding an app
  - `home-ops-app-pattern` — bjw-s app-template HelmRelease shape
  - `home-ops-create-httproute` — HTTPRoute authoring (internal/external/dual)
  - `home-ops-network-troubleshooting` — Gateway/Tailscale/ExternalDNS/cert diagnostics
  - `home-ops-initial-bootstrap` — Cilium CA + Hubble TLS one-time setup
  - `home-ops-external-secrets` — 1Password Connect `ExternalSecret` convention

## Workstation Secrets

1Password-backed env vars for workstation CLIs live in a tracked template at the repo root and resolve to a gitignored `.env` via `op inject`.

```bash
mise run secrets:env      # refresh .env from .op.env (requires `op` signed in)
mise run kopia:connect    # connect local kopia CLI to the kopiur-managed repo
mise exec -- kopia snapshot ls
```

- `.op.env` holds `op://…` URI templates in commented sections (`# ─── kopia ───` is the first). Values mirror the corresponding in-cluster `ExternalSecret` items.
- Adding a new tool: append `KEY="op://vault/item/field"` lines inside a new commented section in `.op.env`, then `mise run secrets:env` to refresh.
- `.env` is gitignored and never tracked. Do not add manual entries there — use `mise.toml [env]` for persistent vars.
- Tool-specific helpers (e.g. `kopia:connect`) live as one-line mise tasks alongside `secrets:env`.
