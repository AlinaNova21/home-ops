#!/bin/bash

# deploy-infrastructure.sh - Deploy core Kubernetes infrastructure
# Usage: ./deploy-infrastructure.sh [component]

set -euo pipefail

COMPONENT="${1:-all}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S_DIR="$(dirname "$SCRIPT_DIR")"

echo "🚀 Deploying Kubernetes infrastructure components"
echo "📁 Kubernetes directory: $K8S_DIR"
echo "🔧 Component: $COMPONENT"
echo

# Function to check if kubectl is available
check_kubectl() {
    if ! command -v kubectl &> /dev/null; then
        echo "❌ kubectl not found. Please install kubectl first."
        exit 1
    fi
    
    if ! kubectl cluster-info &> /dev/null; then
        echo "❌ kubectl not configured or cluster not accessible"
        exit 1
    fi
    
    echo "✅ kubectl configured and cluster accessible"
}

# Function to check if Helm is available
check_helm() {
    if ! command -v helm &> /dev/null; then
        echo "❌ Helm not found. Please install Helm first."
        exit 1
    fi
    
    echo "✅ Helm available"
}

# Function to wait for deployment
wait_for_deployment() {
    local namespace="$1"
    local deployment="$2"
    local timeout="${3:-300}"
    
    echo "⏳ Waiting for $deployment in $namespace to be ready..."
    if kubectl wait --for=condition=available deployment/"$deployment" -n "$namespace" --timeout="${timeout}s"; then
        echo "✅ $deployment is ready"
    else
        echo "❌ $deployment failed to become ready within ${timeout}s"
        return 1
    fi
}

# Function to wait for pods
wait_for_pods() {
    local namespace="$1"
    local label_selector="$2"
    local timeout="${3:-300}"
    
    echo "⏳ Waiting for pods with label $label_selector in $namespace..."
    if kubectl wait --for=condition=ready pods -l "$label_selector" -n "$namespace" --timeout="${timeout}s"; then
        echo "✅ Pods are ready"
    else
        echo "❌ Pods failed to become ready within ${timeout}s"
        return 1
    fi
}

# Deploy Envoy Gateway
deploy_envoy_gateway() {
    echo "📦 Deploying Envoy Gateway..."
    
    # Check if Envoy Gateway is already installed
    if kubectl get deployment envoy-gateway -n envoy-gateway-system &> /dev/null; then
        echo "ℹ️  Envoy Gateway already installed"
    else
        echo "📥 Installing Envoy Gateway..."
        kubectl apply -f https://github.com/envoyproxy/gateway/releases/download/v0.6.0/install.yaml
        wait_for_deployment "envoy-gateway-system" "envoy-gateway" 300
    fi
    
    # Deploy main gateway
    echo "🌐 Deploying homelab gateway..."
    kubectl apply -f "$K8S_DIR/gateway/gateway.yaml"
    
    echo "✅ Envoy Gateway deployment completed"
}

# Deploy CloudNativePG
deploy_cloudnative_pg() {
    echo "🐘 Deploying CloudNativePG..."
    
    # Create databases namespace
    kubectl create namespace databases --dry-run=client -o yaml | kubectl apply -f -
    
    # Check if CloudNativePG is already installed
    if kubectl get deployment cnpg-controller-manager -n cnpg-system &> /dev/null; then
        echo "ℹ️  CloudNativePG already installed"
    else
        echo "📥 Installing CloudNativePG operator..."
        kubectl apply -f https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.20/releases/cnpg-1.20.0.yaml
        wait_for_deployment "cnpg-system" "cnpg-controller-manager" 300
    fi
    
    # Deploy PostgreSQL cluster
    echo "🗄️  Deploying PostgreSQL cluster..."
    
    # Generate passwords for database users if secrets don't exist
    if ! kubectl get secret homelab-postgres-superuser -n databases &> /dev/null; then
        echo "🔐 Creating PostgreSQL superuser secret..."
        kubectl create secret generic homelab-postgres-superuser \
            --from-literal=username=postgres \
            --from-literal=password="$(openssl rand -base64 32)" \
            -n databases
    fi
    
    # Update password secrets in the YAML before applying
    TEMP_DB_FILE="/tmp/homelab-postgres-updated.yaml"
    cp "$K8S_DIR/databases/homelab-postgres.yaml" "$TEMP_DB_FILE"
    
    # Generate and replace passwords
    IMMICH_PASS=$(openssl rand -base64 32)
    PAPERLESS_PASS=$(openssl rand -base64 32)
    AUTHENTIK_PASS=$(openssl rand -base64 32)
    VIKUNJA_PASS=$(openssl rand -base64 32)
    
    sed -i "s/CHANGE_ME_IMMICH_PASSWORD/$IMMICH_PASS/g" "$TEMP_DB_FILE"
    sed -i "s/CHANGE_ME_PAPERLESS_PASSWORD/$PAPERLESS_PASS/g" "$TEMP_DB_FILE"
    sed -i "s/CHANGE_ME_AUTHENTIK_PASSWORD/$AUTHENTIK_PASS/g" "$TEMP_DB_FILE"
    sed -i "s/CHANGE_ME_VIKUNJA_PASSWORD/$VIKUNJA_PASS/g" "$TEMP_DB_FILE"
    
    kubectl apply -f "$TEMP_DB_FILE"
    rm -f "$TEMP_DB_FILE"
    
    # Wait for cluster to be ready
    echo "⏳ Waiting for PostgreSQL cluster to be ready..."
    kubectl wait --for=condition=Ready cluster/homelab-postgres -n databases --timeout=600s
    
    echo "✅ CloudNativePG deployment completed"
}

# Deploy External Secrets Operator
deploy_external_secrets() {
    echo "🔐 Deploying External Secrets Operator..."
    
    # Check if External Secrets Operator is already installed
    if kubectl get deployment external-secrets -n external-secrets-system &> /dev/null; then
        echo "ℹ️  External Secrets Operator already installed"
    else
        echo "📥 Installing External Secrets Operator..."
        helm repo add external-secrets https://charts.external-secrets.io
        helm repo update
        
        kubectl create namespace external-secrets-system --dry-run=client -o yaml | kubectl apply -f -
        
        helm install external-secrets external-secrets/external-secrets \
            --namespace external-secrets-system \
            --set installCRDs=true
            
        wait_for_deployment "external-secrets-system" "external-secrets" 300
        wait_for_deployment "external-secrets-system" "external-secrets-cert-controller" 300
        wait_for_deployment "external-secrets-system" "external-secrets-webhook" 300
    fi
    
    echo "✅ External Secrets Operator deployment completed"
}

# Deploy VolSync
deploy_volsync() {
    echo "💾 Deploying VolSync..."
    
    # Check if VolSync is already installed
    if kubectl get deployment volsync -n volsync-system &> /dev/null; then
        echo "ℹ️  VolSync already installed"
    else
        echo "📥 Installing VolSync..."
        helm repo add backube https://backube.github.io/helm-charts/
        helm repo update
        
        kubectl create namespace volsync-system --dry-run=client -o yaml | kubectl apply -f -
        
        helm install volsync backube/volsync \
            --namespace volsync-system
            
        wait_for_deployment "volsync-system" "volsync" 300
    fi
    
    echo "✅ VolSync deployment completed"
}

# Deploy monitoring stack (optional)
deploy_monitoring() {
    echo "📊 Deploying monitoring stack..."
    
    # Create monitoring namespace
    kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
    
    # Add Prometheus community Helm repository
    helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
    helm repo update
    
    # Install kube-prometheus-stack
    if helm list -n monitoring | grep -q kube-prometheus-stack; then
        echo "ℹ️  Prometheus stack already installed"
    else
        echo "📥 Installing Prometheus stack..."
        helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
            --namespace monitoring \
            --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
            --set prometheus.prometheusSpec.podMonitorSelectorNilUsesHelmValues=false \
            --set prometheus.prometheusSpec.ruleSelectorNilUsesHelmValues=false
            
        wait_for_deployment "monitoring" "kube-prometheus-stack-operator" 300
    fi
    
    echo "✅ Monitoring stack deployment completed"
}

# Main deployment function
deploy_all() {
    echo "🌟 Deploying all infrastructure components..."
    
    deploy_envoy_gateway
    echo
    deploy_external_secrets
    echo
    deploy_volsync
    echo
    deploy_cloudnative_pg
    echo
    deploy_monitoring
    echo
    
    echo "🎉 All infrastructure components deployed successfully!"
    
    # Show status summary
    echo
    echo "📊 Infrastructure Status Summary:"
    echo "=================================="
    
    echo "🌐 Envoy Gateway:"
    kubectl get pods -n envoy-gateway-system | grep envoy-gateway || echo "   Not found"
    
    echo "🐘 CloudNativePG:"
    kubectl get clusters -n databases || echo "   Not found"
    
    echo "🔐 External Secrets:"
    kubectl get pods -n external-secrets-system | grep external-secrets || echo "   Not found"
    
    echo "💾 VolSync:"
    kubectl get pods -n volsync-system | grep volsync || echo "   Not found"
    
    echo "📊 Monitoring:"
    kubectl get pods -n monitoring | head -5 || echo "   Not found"
    
    echo
    echo "🚀 Next steps:"
    echo "1. Configure External Secrets Operator with your Vault server"
    echo "2. Set up TLS certificates for the gateway"
    echo "3. Begin application migration using the conversion tools"
}

# Pre-flight checks
check_kubectl
check_helm

# Helm repository updates
echo "📦 Updating Helm repositories..."
helm repo update

# Deploy based on component selection
case "$COMPONENT" in
    "envoy-gateway"|"gateway")
        deploy_envoy_gateway
        ;;
    "cloudnative-pg"|"cnpg"|"postgres")
        deploy_cloudnative_pg
        ;;
    "external-secrets"|"eso")
        deploy_external_secrets
        ;;
    "volsync"|"backup")
        deploy_volsync
        ;;
    "monitoring"|"prometheus")
        deploy_monitoring
        ;;
    "all"|*)
        deploy_all
        ;;
esac

echo
echo "✅ Infrastructure deployment completed!"
echo "📄 Check logs above for any issues"
echo "🔧 Use 'kubectl get pods --all-namespaces' to verify all components"