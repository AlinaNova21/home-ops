#!/usr/bin/env bash
set -euo pipefail

# Bootstrap script for Flux CD
# This script installs Flux initially, then Flux manages itself via HelmRelease

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLUX_CONFIG_DIR="${SCRIPT_DIR}/flux-config"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."

    local missing=()

    command -v kubectl &>/dev/null || missing+=("kubectl")
    command -v flux &>/dev/null || missing+=("flux")
    command -v helm &>/dev/null || missing+=("helm")

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required tools: ${missing[*]}"
        log_info "Install with: mise install"
        exit 1
    fi

    # Check cluster connectivity
    if ! kubectl cluster-info &>/dev/null; then
        log_error "Cannot connect to Kubernetes cluster. Check your kubeconfig."
        exit 1
    fi

    log_info "All prerequisites met"
}

# Install Flux using the CLI (initial bootstrap)
install_flux() {
    log_info "Installing Flux controllers..."

    # Check if Flux is already installed
    if kubectl get namespace flux-system &>/dev/null; then
        if kubectl get deployment -n flux-system source-controller &>/dev/null; then
            log_warn "Flux appears to be already installed"
            read -p "Do you want to reinstall? (y/N) " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                log_info "Skipping Flux installation"
                return 0
            fi
        fi
    fi

    # Install Flux using the CLI
    # This installs the controllers without creating a GitRepository
    flux install \
        --components-extra=image-reflector-controller,image-automation-controller \
        --export > /dev/null  # Dry run first

    flux install \
        --components-extra=image-reflector-controller,image-automation-controller

    log_info "Waiting for Flux controllers to be ready..."
    kubectl wait --for=condition=available --timeout=300s deployment/source-controller -n flux-system
    kubectl wait --for=condition=available --timeout=300s deployment/kustomize-controller -n flux-system
    kubectl wait --for=condition=available --timeout=300s deployment/helm-controller -n flux-system
    kubectl wait --for=condition=available --timeout=300s deployment/notification-controller -n flux-system

    log_info "Flux controllers are ready"
}

# Apply flux-config so Flux manages itself
apply_flux_config() {
    log_info "Applying flux-config for self-management..."

    # First, apply the namespace (should already exist from flux install)
    kubectl apply -f "${FLUX_CONFIG_DIR}/namespace.yaml"

    # Apply repositories (HelmRepository and OCIRepository)
    kubectl apply -k "${FLUX_CONFIG_DIR}/registry/oci"
    kubectl apply -k "${FLUX_CONFIG_DIR}/registry/helm"

    # Apply the HelmRelease for Flux to manage itself
    kubectl apply -f "${FLUX_CONFIG_DIR}/flux-helmrelease.yaml"

    # Apply the root Kustomization that points to the flat cluster layout
    kubectl apply -f "${FLUX_CONFIG_DIR}/cluster.yaml"

    log_info "Flux is now configured for self-management"
}

# Wait for reconciliation
wait_for_reconciliation() {
    log_info "Waiting for initial reconciliation..."

    # Wait for OCIRepository to be ready
    log_info "Waiting for OCIRepository..."
    kubectl wait --for=condition=ready --timeout=300s ocirepository/home-ops -n flux-system || true

    # Wait for HelmRelease to be ready
    log_info "Waiting for Flux HelmRelease..."
    kubectl wait --for=condition=ready --timeout=600s helmrelease/flux2 -n flux-system || true

    # Wait for cluster Kustomization
    log_info "Waiting for cluster Kustomization..."
    kubectl wait --for=condition=ready --timeout=600s kustomization/cluster -n flux-system || true

    log_info "Initial reconciliation complete"
}

# Show status
show_status() {
    log_info "Flux Status:"
    echo
    flux get all -A
    echo
    log_info "Bootstrap complete!"
    log_info ""
    log_info "Flux is now managing itself via HelmRelease."
    log_info "Any changes to flux-config/ will be automatically applied."
    log_info ""
    log_info "Useful commands:"
    log_info "  flux get all -A              # Show all Flux resources"
    log_info "  flux reconcile source oci home-ops  # Force reconcile"
    log_info "  flux logs -A                 # View Flux logs"
}

# Main
main() {
    log_info "Starting Flux bootstrap..."
    echo

    check_prerequisites
    install_flux
    apply_flux_config
    wait_for_reconciliation
    show_status
}

# Run main unless sourced
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
