# Komodo Resources - GitOps Management
# Usage: just <command>

# =============================================================================
# Configuration
# =============================================================================

registry := "ghcr.io/alinanova21"
repo_name := "home-ops"
oci_url := registry + "/" + repo_name
git_url := "https://github.com/AlinaNova21/home-ops"

bootstrap_dir := "kubernetes/bootstrap"
sops_age_key_file := "~/.config/sops/age/keys.txt"

# Install the local pre-commit hook (gitleaks + trufflehog) using mise
hooks-install:
    mise run hooks:install

# Default recipe - show available commands
default:
    @just --list --unsorted

# =============================================================================
# Cluster Bootstrap (Cilium + Flux)
# =============================================================================

# Upgrade Kubernetes version (TOPF does not orchestrate k8s upgrades)
talos-upgrade-k8s:
    talosctl upgrade-k8s

# Install Cilium CNI only
bootstrap-cilium:
    helm repo add cilium https://helm.cilium.io/ 2>/dev/null || true
    helm repo update cilium
    helm upgrade --install cilium cilium/cilium \
        --namespace kube-system \
        --version 1.19.4 \
        -f {{bootstrap_dir}}/cilium-values.yaml \
        --wait --timeout 5m

# Bootstrap Cilium and Flux Operator using Helmfile
bootstrap-helmfile:
    cd {{bootstrap_dir}} && helmfile apply

# Full bootstrap: Cilium + Flux Operator + Flux self-management via GitOps
bootstrap: bootstrap-helmfile bootstrap-sops-key

# Install the Flux SOPS age key Secret (one-shot per cluster rebuild).
# Decrypts kubernetes/bootstrap/flux-age-key.sops.yaml with the personal age key
# and applies Secret/flux-system/sops-age, then forces Flux to reconcile the
# flux-config Kustomization which decrypts and applies the 1Password Connect
# credentials Secret from kubernetes/flux-system/flux-config/app/.
bootstrap-sops-key:
    SOPS_AGE_KEY_FILE={{ sops_age_key_file }} \
        sops -d kubernetes/bootstrap/flux-age-key.sops.yaml | kubectl apply -f -
    flux reconcile kustomization flux-config -n flux-system

# =============================================================================
# Flux Operations
# =============================================================================

# Build and push OCI artifact with kubernetes manifests
flux-push:
    flux push artifact oci://{{oci_url}}:latest \
        --path="./kubernetes" \
        --source="$(git config --get remote.origin.url)" \
        --revision="$(git rev-parse HEAD)"
    kubectl annotate --overwrite ocirepository/home-ops -n flux-system \
        reconcile.fluxcd.io/requestedAt="$(date +%s)" || true

# Reconcile Flux sources
flux-sync:
    kubectl annotate --overwrite ocirepository/home-ops -n flux-system \
        reconcile.fluxcd.io/requestedAt="$(date +%s)"
    flux reconcile kustomization cluster -n flux-system || true

# Reconcile Git source (new GitRepository-based flow)
git-flux-sync:
    kubectl annotate --overwrite gitrepository/home-ops -n flux-system \
        reconcile.fluxcd.io/requestedAt="$(date +%s)"
    flux reconcile kustomization cluster -n flux-system || true

# Check Flux status
flux-status:
    @echo "Controllers:"
    @kubectl get pods -n flux-system
    @echo "\nSources:"
    @kubectl get ocirepositories,gitrepositories -n flux-system
    @echo "\nKustomizations:"
    @kubectl get kustomizations -n flux-system
    @echo "\nHelm Releases:"
    @kubectl get helmreleases -A

# Deploy: push OCI artifact and sync
deploy: flux-push flux-sync

# Deploy via Git source (new GitRepository-based flow)
git-deploy: git-flux-sync

# =============================================================================
# Cilium Operations
# =============================================================================

# Check Cilium status
cilium-status:
    cilium status --wait

# =============================================================================
# Pulumi
# =============================================================================

# Deploy Pulumi infrastructure
pulumi-up:
    cd pulumi && pulumi up

# =============================================================================
# Flate
# =============================================================================

# Render all Flux objects to YAML
# Usage: just flate-build [extra flate args]
flate-build *args:
    flate build all -p kubernetes {{args}}

# Validate all Kustomizations, HelmReleases, and Flux sources
# Usage: just flate-test [extra flate args]
flate-test *args:
    flate test all -p kubernetes {{args}}

# Diff rendered output against main branch
# Usage: just flate-diff
flate-diff:
    flate diff all -p kubernetes --base main

# =============================================================================
# Worktree Management
# =============================================================================

# Create a new worktree for a feature branch (based on main)
worktree-create branch:
	git worktree add .worktrees/{{branch}} -b {{branch}} main

# Check out an existing remote branch as a worktree (e.g. Renovate PRs)
worktree-add branch:
	git fetch origin {{branch}} 2>/dev/null || true
	git worktree add .worktrees/{{branch}} origin/{{branch}}

# Remove a worktree (with local branch cleanup)
worktree-clean branch:
	git worktree remove .worktrees/{{branch}} && \
	git branch -D {{branch}} 2>/dev/null || true

# List all linked worktrees
worktree-list:
	git worktree list

# =============================================================================
# Cleanup
# =============================================================================

# Destroy Flux and applications (keeps cluster)
destroy-flux:
    kubectl delete helmreleases --all -n flux-system || true
    kubectl delete kustomizations --all -n flux-system || true
    kubectl delete ocirepositories --all -n flux-system || true
    kubectl delete gitrepositories --all -n flux-system || true
    kubectl delete helmrepositories --all -n flux-system || true
    kubectl delete namespace flux-system || true

# Destroy everything (Pulumi + FluxCD)
destroy: destroy-flux
    cd pulumi && pulumi destroy
