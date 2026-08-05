# AGENTS.md - home-ops Repository

Primary agent instructions for the home-ops repository. Covers Kubernetes infrastructure managed by Flux CD GitOps. For Talos Linux node configuration, see `talos/AGENTS.md`.

## Tooling

The repo's `mise.toml` pins the full toolchain: `talosctl`, `talhelper`, `kubectl`, `helm`, `helmfile`, `flux2`, `cilium-cli`, `k9s`, `sops`, `age`, `just`, `jq`, `yq`, `pre-commit`, `gitleaks`, `trufflehog`, `k8sgpt`, `kopia`, `flux-operator`, `flux-operator-mcp`, `kubeconform`, `flate`, `crane`. Note: `kustomize` is **not** pinned — use `flate` for local rendering/validation (CI installs kustomize itself).

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

## Agent Operating Rules

These rules apply to every agent operating in this repo, regardless of model
or session. They override any heuristic that would otherwise optimize for
"just getting it done."

### Explicit-orders gates

The following actions require the user to give an **explicit, scoped** order
in the current turn ("merge it", "yes, push to main", "do it"). Do **not**
infer consent from a green CI, a passing plan, or a previous "create a PR"
request.

| Action | Why it's gated |
|---|---|
| `gh pr merge …` (any flag combo: `--merge`, `--squash`, `--rebase`, `--auto`, `--delete-branch`) | Merges publish to `main` and trigger Flux reconciliation cluster-wide. |
| `git push` to `main` / `master` (including Renovate's auto-merge targets) | Direct push bypasses PR review. |
| `git push --force` / `--force-with-lease` to any shared branch | Rewrites published history. |
| `git reset --hard` / `git commit --amend` on a published commit | Destroys or rewrites published history. |
| `git branch -D` on a branch that exists on `origin` | Deletes shared work. |
| `kubectl delete` against `flux-system`, `kube-system`, `cert-manager`, `external-secrets-system`, `storage`, `network`, `monitoring`, `auth` — or any resource with `reconcile.external-secrets.io/managed=true` | Cluster state damage; some are irrecoverable without reinstall. |
| `kubectl scale --replicas=0` or `kubectl drain` on control-plane / storage nodes | Cluster availability impact. |
| `flux suspend …` / `flux uninstall` | Disables or removes GitOps control plane. |
| `terraform apply` / `terraform destroy` | Infra state changes. |
| `rm -rf` against paths outside `/tmp/opencode` | Data loss. |
| Modifying `~/.config/opencode/`, `opencode.json`, or this repo's `.opencode/` | Changes the agent itself. |

Safe without explicit orders: `git add`, `git commit` (local only), `git push`
to a feature branch, `gh pr create` / `gh pr edit` / `gh pr comment`,
`kubectl get` / `describe` / `logs`, `flux reconcile`, `flux resume`,
`kustomize build`, `kubeconform`, pre-commit hooks, file edits within the
working tree.

If unsure whether an action is gated: **ask before doing it**. A two-line
question is always cheaper than an unwanted merge.

### Workflow expectations

- **Stage, don't surprise.** Announce what you're about to do when the
  action is destructive or visible (cluster-wide reconcile, secret
  rotation, mass deletion).
- **Verify before claiming done.** Per the project's `verification-before-completion`
  expectation: run the check, paste the output, then assert success.
- **Stop on user pushback.** If the user says "wait", "stop", or "did I
  say X?", halt immediately. Summarize current state and wait for
  direction — do not try to "fix" the situation with more changes.

### Worktree Operating Rules

All agents MUST follow these rules when modifying files in this repo:

1. **Load the `home-ops-worktree-workflow` skill** before making any file changes
2. **Work in a worktree** unless already in one (`.worktrees/<branch-name>`)
3. **No nested worktrees** — detect existing isolation first
4. **Clean up** when done — `just worktree-clean <branch-name>`
5. The explicit-orders gates above still apply regardless of worktree isolation

Validation gates:
- Run `just flate-test` **before** making changes (baseline)
- Run `pre-commit run --all-files` + `just flate-test` **before** every commit
- Do not commit through failing validation

Secrets:
- `.env` is gitignored and not shared across worktrees
- Run `mise run secrets:env` in each new worktree to regenerate `.env`

Branch naming:
- Feature branches: `feat/<short-description>`
- Fix branches: `fix/<short-description>`
- Worktree directory mirrors branch name: `.worktrees/<branch-name>`

## Architecture Overview

- **GitOps Engine**: Flux CD deployed via Flux Operator (`FluxInstance/flux` in `flux-system`); `GitRepository home-ops` (HTTPS, branch=main, poll interval; OCI artifact retained dormant as rollback insurance). The single `Kustomization/cluster` lives at `kubernetes/ks.yaml` and reconciles `./kubernetes`
- **Resource Composition**: Kustomize layering with Helm charts
- **Helm Charts**: bjw-s app-template delivered via OCI — per-app `OCIRepository` (`oci://ghcr.io/bjw-s-labs/helm/app-template`, cosign-verified) + `helm.toolkit.fluxcd.io/v2` HelmRelease using `chartRef`
- **Secrets**: External Secrets Operator syncing from 1Password Connect (`ClusterSecretStore: onepassword-connect`)
- **Ingress**: Envoy Gateway with Gateway API HTTPRoutes
  - External Gateway: Cloudflare Tunnel, TLS terminated at origin (Cloudflare Origin CA) — `*.whoverse.nexus` + `*.beee.gay`
  - Internal Gateway: Tailscale VPN with HA for private access (`*.whoverse.dev`)
- **Networking**: Cilium CNI with BGP, Tailscale operator for VPN LoadBalancer
- **Storage**: miroir (`miroir-replicated` default, `miroir-local`); rook-ceph and openebs-localpv disabled (pending cluster reset); zot OCI registry

### Networks

| Network | Range | Notes |
|---|---|---|
| LAN (br0, native/untagged) | `192.168.2.0/24` | Talos nodes; API VIP `192.168.2.20` |
| Tailscale | `100.x` | Internal gateway (`*.whoverse.dev`), pve-egress relay |

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

The `Kustomization/cluster` at `kubernetes/ks.yaml` reconciles `./kubernetes` (the whole tree). There is no `apps/` or `infrastructure/` group directory.

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

### Layout guide

The namespace list changes often — `ls kubernetes/` is the live view and the top-level `kubernetes/kustomization.yaml` aggregator is the authoritative list of active namespaces. Don't trust a static tree.

Reconcile scope: everything under `kubernetes/` is app code except the meta dirs below. Layout follows the flat Namespace → Component → Resources hierarchy above; the pre-commit hook enforces rules 1–4.

Meta directories (not reconciled as namespaces):

| Dir | Purpose |
|---|---|
| `components/` | Cross-cutting Kustomize components (e.g. `kopiur/backup`), referenced via component `ks.yaml` `components:` |
| `bootstrap/` | Cilium + Flux helmfile, one-shot first install |
| `flux-config/` | Flux self-management: GitRepository, registry sources, sops (`flux-sops` Kustomization) |
| `scripts/` | deploy-infrastructure.sh, add-yaml-modelines.py |

## Deployment Workflow

### Production (GitOps)

```bash
# 1. Edit manifests
# 2. Commit + push
git add .
git commit -m "..."
git push

# 3. Flux picks up automatically (poll interval); force reconcile if needed:
flux reconcile source git home-ops -n flux-system
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
| `just flux-status` | Pods, OCIRepositories, GitRepositories, Kustomizations, HelmReleases |
| `just git-deploy` | `git-flux-sync` (annotate GitRepository + reconcile cluster) |
| `just git-flux-sync` | Annotate GitRepository + reconcile cluster |
| `just deploy` | `flux-push` + `flux-sync` (OCI flow — dormant, for rollback only) |
| `just flux-push` | Build OCI artifact locally and annotate OCIRepository (dormant) |
| `just flux-sync` | Annotate OCIRepository + reconcile cluster (dormant) |
| `just cilium-status` | `cilium status --wait` |
| `just destroy-flux` | Remove all Flux resources (keeps cluster) |
| `just flate-test` | Validate Flux resources (`flate test all`) — pre-commit gate |
| `just flate-build` | Render all Flux objects to YAML |
| `just flate-diff` | Diff rendered output against `main` |
| `just bootstrap` | Full bootstrap: Cilium + Flux Operator + Flux self-management |
| `just bootstrap-helmfile` | Cilium + Flux Operator via helmfile |
| `just bootstrap-cilium` | Install Cilium CNI only |
| `just bootstrap-sops-key` | Install Flux SOPS age key (one-shot per cluster rebuild) |
| `just worktree-create <branch>` | Create feature branch worktree from `main` |
| `just worktree-add <branch>` | Check out existing remote branch as worktree |
| `just worktree-clean <branch>` | Remove worktree + local branch |
| `just worktree-list` | Show all linked worktrees |

See `talos/AGENTS.md` for Talos recipes (`talos-gen`, `talos-apply`, `talos-bootstrap`, etc.).

## Validation

**CI** runs in `.github/workflows/validate-kubernetes.yml`: `kustomize build` + `kubeconform` against `kubernetes/flux-config` and `kubernetes/` (root aggregator).

**Local equivalent** — flate is the primary gate (no `helm`/`kustomize`/`flux` binaries needed):

```bash
just flate-test                    # validate every Kustomization/HelmRelease/source
just flate-test --allow-missing-secrets   # skip refs that only exist in the cluster
just flate-build                   # render all resources
just flate-diff                    # diff against main
```

CI-equivalent kubeconform check (matches `.github/workflows/validate-kubernetes.yml`):

```bash
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
  - `home-ops-flate` — flate validation and diff (the local validation gate)
  - `home-ops-worktree-workflow` — Isolation via git worktrees (load before any file changes)

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

## SOPS for Flux

Flux decrypts `kubernetes/flux-config/sops/*.sops.yaml` using a dedicated age key that lives in the cluster as `Secret/flux-system/sops-age`. The key is generated once during initial setup and bootstrapped manually after a fresh cluster install.

### Keys

| File | Purpose | `.sops.yaml` rule |
|---|---|---|
| `~/.config/sops/age/keys.txt` | Personal age key — decrypts k8s bootstrap + Talos | `kubernetes/bootstrap/`, `talos/` |
| `Secret/flux-system/sops-age` (in cluster) | Flux-only age key — decrypts Flux-managed k8s | `kubernetes/flux-config/sops/` |

The personal key is also a recipient on `kubernetes/flux-config/sops/*.sops.yaml` (dual recipients) so the operator can decrypt locally without touching the cluster Secret.

### One-shot bootstrap (per cluster rebuild)

```bash
just bootstrap-sops-key
```

This decrypts `kubernetes/bootstrap/flux-age-key.sops.yaml` with the personal key, applies `Secret/flux-system/sops-age` to the cluster, and forces Flux to reconcile `Kustomization/flux-sops` — which then decrypts and applies the 1Password Connect credentials Secret from `kubernetes/flux-config/sops/`.

### Adding a new k8s SOPS file

Drop the file under `kubernetes/flux-config/sops/`, add it to `kubernetes/flux-config/sops/kustomization.yaml`. The matching `.sops.yaml` rule already covers any new file in that directory — no rule edit needed.

```bash
# Encrypt in place after authoring the Secret manifest
SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt sops -e -i kubernetes/flux-config/sops/<name>.sops.yaml
```

### Flux age key rotation

```bash
# 1. Generate a new keypair (ephemeral /tmp keyfile)
age-keygen -o /tmp/flux-home-ops.txt.new
NEW_PUB=$(grep '# public key:' /tmp/flux-home-ops.txt.new | awk '{print $NF}')

# 2. Update .sops.yaml with the new public key in the flux-config/sops rule
# 3. Re-encrypt all files under kubernetes/flux-config/sops/
SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt:/tmp/flux-home-ops.txt \
  sops updatekeys -y kubernetes/flux-config/sops/*.sops.yaml

# 4. Re-encrypt the bootstrap Secret with the new private key
python3 -c "
import textwrap
with open('/tmp/flux-home-ops.txt.new') as f:
    print(textwrap.dedent('''
apiVersion: v1
kind: Secret
metadata:
  name: sops-age
  namespace: flux-system
type: Opaque
stringData:
  sops.agekey: |
''').lstrip() + textwrap.indent(f.read().rstrip(), '    '))
" > kubernetes/bootstrap/flux-age-key.sops.yaml
SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt \
  sops -e -i kubernetes/bootstrap/flux-age-key.sops.yaml

# 5. Discard the temporary keyfile
rm -f /tmp/flux-home-ops.txt.new

# 6. Commit + push, then re-run the bootstrap
git add .sops.yaml kubernetes/bootstrap/flux-age-key.sops.yaml kubernetes/flux-config/sops/
git commit -m "chore(sops): rotate Flux age key"
git push
just bootstrap-sops-key
```
