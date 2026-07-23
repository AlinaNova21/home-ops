# Komodo Resources - GitOps Management
# Usage: just <command>

# =============================================================================
# Configuration
# =============================================================================

registry := "ghcr.io/alinanova21"
repo_name := "home-ops"
oci_url := registry + "/" + repo_name

talos_dir := "talos/whoverse"
talos_config := talos_dir + "/clusterconfig"
bootstrap_dir := "kubernetes/bootstrap"

# Default recipe - show available commands
default:
    @just --list --unsorted

# =============================================================================
# Talos Cluster Management
# =============================================================================

# Generate Talos configs from talconfig.yaml
talos-gen:
    cd {{talos_dir}} && talhelper genconfig

# Apply Talos configs to all nodes (requires existing trust)
talos-apply: talos-gen
    cd {{talos_dir}} && talhelper gencommand apply | bash

# Apply Talos configs with --insecure flag (for initial setup)
talos-apply-insecure: talos-gen
    cd {{talos_dir}} && talhelper gencommand apply --extra-flags --insecure | bash

# Bootstrap Talos cluster (first time only)
talos-bootstrap: talos-apply-insecure
    cd {{talos_dir}} && talhelper gencommand bootstrap | bash

# Get Talos cluster health
talos-health:
    cd {{talos_dir}} && talhelper gencommand health | bash

# Get kubeconfig from Talos cluster
talos-kubeconfig:
    cd {{talos_dir}} && talhelper gencommand kubeconfig --extra-flags "--force" | bash

# Upgrade Talos on all nodes
talos-upgrade:
    cd {{talos_dir}} && talhelper gencommand upgrade | bash

# Upgrade Kubernetes version
talos-upgrade-k8s:
    cd {{talos_dir}} && talhelper gencommand upgrade-k8s | bash

# Reset Talos nodes (destructive!)
talos-reset:
    cd {{talos_dir}} && talhelper gencommand reset | bash

# =============================================================================
# Cluster Bootstrap (Cilium + Flux)
# =============================================================================

# Install Cilium CNI only
bootstrap-cilium:
    helm repo add cilium https://helm.cilium.io/ 2>/dev/null || true
    helm repo update cilium
    helm upgrade --install cilium cilium/cilium \
        --namespace kube-system \
        --version 1.19.4 \
        -f {{bootstrap_dir}}/cilium-values.yaml \
        --wait --timeout 5m

# Install Flux only
bootstrap-flux:
    helm repo add fluxcd-community oci://ghcr.io/fluxcd-community/charts 2>/dev/null || true
    helm upgrade --install flux2 fluxcd-community/flux2 \
        --namespace flux-system \
        --create-namespace \
        --version 2.16.2 \
        -f {{bootstrap_dir}}/flux-values.yaml \
        --wait --timeout 5m

# Bootstrap Cilium and Flux using Helmfile
bootstrap-helmfile:
    cd {{bootstrap_dir}} && helmfile apply

# Configure Flux for self-management after bootstrap
flux-configure:
    kubectl apply -f kubernetes/flux-config/namespace.yaml
    kubectl apply -k kubernetes/flux-config/registry/oci
    kubectl apply -k kubernetes/flux-config/registry/helm
    kubectl apply -f kubernetes/flux-config/flux-helmrelease.yaml
    kubectl apply -f kubernetes/flux-config/infrastructure.yaml
    kubectl apply -f kubernetes/flux-config/apps.yaml

# Full bootstrap: Cilium + Flux + self-management config
bootstrap: bootstrap-cilium bootstrap-flux flux-configure

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
    flux reconcile kustomization infrastructure -n flux-system || true
    flux reconcile kustomization apps -n flux-system || true

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
# Cleanup
# =============================================================================

# Destroy Flux and applications (keeps cluster)
destroy-flux:
    kubectl delete kustomizations --all -n flux-system || true
    kubectl delete ocirepositories --all -n flux-system || true
    kubectl delete namespace flux-system || true

# Destroy everything (Pulumi + FluxCD)
destroy: destroy-flux
    cd pulumi && pulumi destroy
