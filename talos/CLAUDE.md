# CLAUDE.md - Talos Directory

This directory contains Talos Linux cluster configurations managed by [talhelper](https://github.com/budimanjojo/talhelper).

## Architecture Overview

- **OS**: Talos Linux (immutable, API-driven Kubernetes OS)
- **Config Management**: talhelper generates talosctl configs from talconfig.yaml
- **Secrets**: SOPS encryption with age keys
- **CNI**: Cilium (installed post-bootstrap, not bundled)

## Cluster: whoverse

| Property | Value |
|----------|-------|
| Nodes | 3 mixed controlplane |
| Node IPs | 192.168.2.21-23 |
| VIP | 192.168.2.20 |
| Talos Version | v1.11.5 |
| Kubernetes Version | v1.34.1 |
| CNI | Cilium |
| Pod Network | 10.244.0.0/16 |
| Service Network | 10.96.0.0/12 |

## Directory Structure

```
talos/
├── whoverse/                # Primary cluster
│   ├── talconfig.yaml       # Cluster configuration (main source of truth)
│   ├── talsecret.sops.yaml  # Encrypted cluster secrets
│   ├── patches/             # Machine config patches
│   │   └── ceph-osd-volume.yaml
│   └── clusterconfig/       # Generated configs (gitignored)
└── README.md
```

## Prerequisites

Tools are managed via [mise](https://mise.jdx.dev) at the repo root:

```bash
mise install
```

This provides `talosctl`, `talhelper`, `sops`, `age`, `kubectl`, `cilium`, `jq`, and `yq`. All versions are pinned in the root `mise.toml`.

## Key Commands

All commands from root Justfile:

```bash
# Generate Talos configs from talconfig.yaml
just talos-gen

# Apply configs to all nodes (requires existing trust)
just talos-apply

# Apply configs with --insecure flag (initial setup)
just talos-apply-insecure

# Bootstrap cluster (first time only)
just talos-bootstrap

# Check cluster health
just talos-health

# Get kubeconfig
just talos-kubeconfig

# Upgrade Talos on all nodes
just talos-upgrade

# Upgrade Kubernetes version
just talos-upgrade-k8s

# Reset nodes (destructive!)
just talos-reset
```

## Initial Setup (New Cluster)

1. **Generate cluster secrets** (first time only):
   ```bash
   cd talos/whoverse
   talhelper gensecret > talsecret.sops.yaml
   sops -e -i talsecret.sops.yaml
   ```

2. **Generate Talos configs**:
   ```bash
   just talos-gen
   ```

3. **Bootstrap cluster** (nodes must be in maintenance mode):
   ```bash
   just talos-bootstrap
   ```

4. **Install Cilium CNI**:
   ```bash
   just talos-kubeconfig
   just bootstrap-cilium
   ```

5. **Bootstrap FluxCD**:
   ```bash
   just bootstrap
   ```

## Day-2 Operations

### Apply Configuration Changes

After editing `talconfig.yaml`:

```bash
just talos-gen    # Regenerate configs
just talos-apply  # Apply to all nodes
```

### Check Cluster Health

```bash
just talos-health
```

### Update Kubeconfig

```bash
just talos-kubeconfig
```

### Upgrade Talos Version

1. Update `talosVersion` in `talconfig.yaml`
2. Run:
   ```bash
   just talos-gen
   just talos-upgrade
   ```

### Upgrade Kubernetes Version

1. Update `kubernetesVersion` in `talconfig.yaml`
2. Run:
   ```bash
   just talos-gen
   just talos-upgrade-k8s
   ```

## Secrets Management

Secrets are encrypted with SOPS using:
- **Age key**: `age16865gej0ndnlnghdq347fur59ht8d7wrcfptdw5ja4fhc4lwdfpq59ratl`
- **GPG key**: `B2266723EDB691FBB16501BC07D6E31CCAE33514`

The age private key is stored at `~/.config/sops/age/keys.txt`.

```bash
# Decrypt secrets (view only)
sops -d talsecret.sops.yaml

# Edit secrets
sops talsecret.sops.yaml
```

## Configuration Reference

### talconfig.yaml Structure

```yaml
clusterName: whoverse
talosVersion: v1.11.5
kubernetesVersion: v1.34.1
endpoint: https://192.168.2.20:6443  # VIP

allowSchedulingOnControlPlanes: true

clusterPodNets:
  - 10.244.0.0/16
clusterSvcNets:
  - 10.96.0.0/12

cniConfig:
  name: none  # Cilium installed separately

schematic:
  customization:
    systemExtensions:
      officialExtensions:
        - siderolabs/iscsi-tools
        - siderolabs/realtek-firmware

nodes:
  - hostname: whoverse-cp1
    ipAddress: 192.168.2.21
    controlPlane: true
    installDisk: /dev/sda
  # ... more nodes

controlPlane:
  patches:
    - "@./patches/ceph-osd-volume.yaml"
  networkInterfaces:
    - interface: br0
      dhcp: true
      bridge:
        interfaces:
          - enp2s0
      vip:
        ip: 192.168.2.20
```

### Patches

Machine config patches are stored in `patches/` and referenced in `talconfig.yaml`:

- **ceph-osd-volume.yaml**: Configures disk for Ceph OSD storage

## Adding a New Cluster

1. Create directory:
   ```bash
   mkdir -p talos/{cluster-name}/patches
   ```

2. Copy and modify `talconfig.yaml` for new cluster

3. Generate secrets:
   ```bash
   cd talos/{cluster-name}
   talhelper gensecret > talsecret.sops.yaml
   sops -e -i talsecret.sops.yaml
   ```

4. Add Justfile recipes for the new cluster

## Troubleshooting

```bash
# Check node status
talosctl -n 192.168.2.21 health

# Get node logs
talosctl -n 192.168.2.21 logs

# Check etcd status
talosctl -n 192.168.2.21 etcd members

# Emergency dashboard
talosctl -n 192.168.2.21 dashboard

# Reset a single node (destructive)
talosctl -n 192.168.2.21 reset
```
