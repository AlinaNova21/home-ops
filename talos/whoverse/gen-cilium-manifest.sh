#!/usr/bin/env bash
# Generate Cilium Helm manifest and patch file for Talos inline bootstrap
# Run this to regenerate patches/cilium-manifests.yaml when upgrading Cilium

set -euo pipefail

CILIUM_VERSION="${1:-1.16.4}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

helm repo add cilium https://helm.cilium.io/ 2>/dev/null || true
helm repo update cilium

# Generate Cilium manifest
CILIUM_MANIFEST=$(helm template cilium cilium/cilium \
  --version "${CILIUM_VERSION}" \
  --namespace kube-system \
  --set kubeProxyReplacement=true \
  --set k8sServiceHost=localhost \
  --set k8sServicePort=7445 \
  --set routingMode=native \
  --set autoDirectNodeRoutes=true \
  --set directRoutingDevice=br0 \
  --set devices=br0 \
  --set bgpControlPlane.enabled=true \
  --set cgroup.autoMount.enabled=false \
  --set cgroup.hostRoot=/sys/fs/cgroup \
  --set securityContext.capabilities.ciliumAgent="{CHOWN,KILL,NET_ADMIN,NET_RAW,IPC_LOCK,SYS_ADMIN,SYS_RESOURCE,DAC_OVERRIDE,FOWNER,SETGID,SETUID}" \
  --set securityContext.capabilities.cleanCiliumState="{NET_ADMIN,SYS_ADMIN,SYS_RESOURCE}")

# Save standalone manifest for manual apply
echo "${CILIUM_MANIFEST}" > "${SCRIPT_DIR}/cilium-install.yaml"
echo "Generated cilium-install.yaml for manual apply (kubectl apply -f cilium-install.yaml)"

# Read BGP bootstrap manifest
BGP_MANIFEST=$(cat "${SCRIPT_DIR}/cilium-bootstrap.yaml")

# Create the patch file with proper indentation
mkdir -p "${SCRIPT_DIR}/patches"
cat > "${SCRIPT_DIR}/patches/cilium-manifests.yaml" << 'HEADER'
cluster:
  inlineManifests:
    - name: cilium
      contents: |
HEADER

# Indent Cilium manifest (8 spaces for YAML block scalar)
# Also escape ${ to prevent talhelper from treating them as template variables
echo "${CILIUM_MANIFEST}" | sed 's/\${/\$\${/g' | sed 's/^/        /' >> "${SCRIPT_DIR}/patches/cilium-manifests.yaml"

cat >> "${SCRIPT_DIR}/patches/cilium-manifests.yaml" << 'MIDDLE'
    - name: cilium-bgp
      contents: |
MIDDLE

# Indent BGP manifest
echo "${BGP_MANIFEST}" | sed 's/^/        /' >> "${SCRIPT_DIR}/patches/cilium-manifests.yaml"

echo "Generated patches/cilium-manifests.yaml for Cilium ${CILIUM_VERSION}"
echo "Reference it in talconfig.yaml with: '@./patches/cilium-manifests.yaml'"
