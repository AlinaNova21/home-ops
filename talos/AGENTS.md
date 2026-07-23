# talos/AGENTS.md - Talos Linux Cluster Configuration

Talos Linux cluster configurations managed by [talhelper](https://github.com/budimanjoaro/talhelper). For repo-wide orientation, see `../AGENTS.md`.

## Cluster spec

Cluster spec (nodes, IPs, VIP, Talos/Kubernetes versions, install disks, network interfaces, schematic extensions) lives in `talos/whoverse/talconfig.yaml` — single source of truth. Run `just talos-gen` after any change.

Ad-hoc queries:

```bash
yq '.nodes | length' talos/whoverse/talconfig.yaml         # node count
yq '.nodes[].hostname' talos/whoverse/talconfig.yaml        # hostnames
yq '.talosVersion, .kubernetesVersion' talos/whoverse/talconfig.yaml
yq '.nodes[].ipAddress' talos/whoverse/talconfig.yaml       # node IPs
```

## Directory Structure

```
talos/
└── whoverse/                # Primary cluster
    ├── talconfig.yaml       # Cluster configuration (source of truth)
    ├── talsecret.sops.yaml  # Encrypted cluster secrets (SOPS: age + GPG)
    ├── ceph-osd-volume.yaml # Per-node machine patch (referenced by talconfig)
    ├── gen-cilium-manifest.sh  # Regenerates Cilium inline manifest for Talos bootstrap
    ├── cilium-bootstrap.yaml   # BGP bootstrap snippet fed into gen-cilium-manifest.sh
    ├── patches/             # Cluster-wide machine config patches
    │   ├── spegel-containerd-config.yaml
    │   └── watchdog.yaml
    └── clusterconfig/       # Generated configs (gitignored)
```

## Prerequisites

User-level tools (`talosctl`, `talhelper`, `sops`, `age`, `kubectl`, `cilium`, `jq`, `yq`) are managed via `~/.config/mise/conf.d/`, not the repo `mise.toml`.

```bash
# Both keys must be available for SOPS decryption:
#   age private key: ~/.config/sops/age/keys.txt
#   GPG private key: local GPG keyring (fingerprint matches .sops.yaml)
```

## Key Commands (Justfile)

```bash
just talos-gen              # Generate Talos configs from talconfig.yaml
just talos-apply            # Apply configs to all nodes (requires existing trust)
just talos-apply-insecure   # Apply with --insecure (initial setup)
just talos-bootstrap        # Bootstrap cluster (first time only)
just talos-health           # Check cluster health
just talos-kubeconfig       # Get kubeconfig from Talos cluster
just talos-upgrade          # Upgrade Talos on all nodes
just talos-upgrade-k8s      # Upgrade Kubernetes version
just talos-reset            # Reset nodes (destructive!)
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

### Upgrade Talos / Kubernetes

1. Update `talosVersion` or `kubernetesVersion` in `talconfig.yaml`
2. Run:
   ```bash
   just talos-gen
   just talos-upgrade          # for Talos
   just talos-upgrade-k8s      # for Kubernetes
   ```

## Secrets Management

`*.sops.yaml` files are encrypted with **age + GPG** (recipient list defined in repo-root `.sops.yaml`). Both recipients can decrypt; adding a recipient never removes existing decrypt capability.

- **Age public key**: `age16865gej0ndnlnghdq347fur59ht8d7wrcfptdw5ja4fhc4lwdfpq59ratl`
- **GPG public key**: `B2266723EDB691FBB16501BC07D6E31CCAE33514`
- **Age private key location**: `~/.config/sops/age/keys.txt`
- **GPG private key location**: local GPG keyring

```bash
# Decrypt secrets (view only)
sops -d talsecret.sops.yaml

# Edit secrets (re-encrypts on save)
sops talsecret.sops.yaml

# Re-key existing files (after .sops.yaml rules change)
sops updatekeys --yes <file>
```

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

4. Add Justfile recipes for the new cluster (parameterize on `talos_dir`)

## Troubleshooting

```bash
# Node status
talosctl -n <node-ip> health

# Node logs
talosctl -n <node-ip> logs

# etcd status
talosctl -n <node-ip> etcd members

# Emergency dashboard
talosctl -n <node-ip> dashboard

# Reset a single node (destructive)
talosctl -n <node-ip> reset
```
