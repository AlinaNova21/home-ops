# talos/AGENTS.md - Talos Linux Cluster Configuration

Talos Linux cluster configurations managed by [TOPF](https://postfinance.github.io/topf/) (Talos Orchestrator by PostFinance). For repo-wide orientation, see `../AGENTS.md`.

## Cluster spec

Cluster spec (nodes, IPs, VIP, Talos/Kubernetes versions, install disks, network interfaces, schematic extensions) lives in `talos/whoverse/topf.yaml` — single source of truth. Machine configs are composed from layered patches (see [Patch Layout](#patch-layout)).

Ad-hoc queries:

```bash
topf nodes                 # list nodes and their state
topf clusterinfo           # non-sensitive cluster info
topf schematic-ids         # resolved schematic IDs per node
```

## Directory Structure

```
talos/
└── whoverse/                # Primary cluster
    ├── topf.yaml            # Cluster configuration (source of truth)
    ├── secrets.yaml         # Encrypted cluster secrets (SOPS: age + GPG)
    ├── schematic.yaml.tpl   # Templated schematic (system extensions; VM nodes get qemu-guest-agent via data.vm)
    ├── all/                 # Patches applied to all nodes
    │   ├── 00-cluster.yaml  # cniConfig, podNets, svcNets, allowSchedulingOnCP
    │   ├── 01-hostname.yaml.tpl  # HostnameConfig from .Node.Host
    │   ├── 02-proxy.yaml    # cluster.proxy.disabled
    │   ├── 03-volumes.yaml  # EPHEMERAL VolumeConfig
    │   ├── 04-spegel.yaml   # spegel containerd config
    │   ├── 05-watchdog.yaml # WatchdogTimerConfig
    │   ├── 06-kernel-miroir.yaml
    │   ├── 07-kubelet-miroir.yaml
    │   └── 08-vip.yaml      # Layer2VIPConfig
    ├── control-plane/       # Patches for control-plane nodes
    │   ├── 00-oidc.yaml     # apiserver OIDC args
    │   ├── 01-talos-api.yaml
    │   └── 02-metrics.yaml  # controllerManager/scheduler bind-address
    ├── worker/               # Patches for worker nodes
    │   └── 00-labels.yaml   # nodeLabels miroir.enabled
    ├── node/                 # Per-host patches
    │   └── <hostname>/
    │       ├── 00-install.yaml  # installDisk
    │       ├── 01-miroir.yaml   # miroir RawVolumeConfig
    │       └── 02-net.yaml      # BridgeConfig + DHCP + BondConfig
    ├── ceph-osd-volume.yaml # Per-node machine patch
    ├── gen-cilium-manifest.sh  # Regenerates Cilium inline manifest for Talos bootstrap
    ├── cilium-bootstrap.yaml   # BGP bootstrap snippet fed into gen-cilium-manifest.sh
    └── clusterconfig/       # Generated configs (gitignored)
```

## Patch Layout

TOPF merges patches in this order (later overrides earlier for same keys):

1. `all/` — applied to all nodes
2. `<role>/` — `control-plane/` or `worker/`
3. `node/<host>/` — applied only to that node

Within each folder, patches apply in **lexicographical order** (hence the `00-`, `01-` prefixes).

**Merge semantics:** strategic merge — maps merge (later wins), **arrays concatenate**. So an array field (e.g. `kernel.modules`, `machine.files`) must appear in at most one patch per node unless concatenation is intended.

**Templating:** patches ending `.yaml.tpl` are Go templates with sprig. Context: `.ClusterName`, `.ClusterEndpoint`, `.KubernetesVersion`, `.TalosVersion`, `.SchematicID`, `.Data.<key>`, `.Node.Host`, `.Node.Role`, `.Node.IP`, `.Node.Data.<key>`. The schematic template uses `hasKey .Node.Data "vm"` to conditionally add `qemu-guest-agent` for VM nodes.

## Prerequisites

Tools (`topf`, `talosctl`, `sops`, `age`, `kubectl`, `cilium`, `jq`, `yq`) are managed via the repo `mise.toml`.

```bash
# Both keys must be available for SOPS decryption:
#   age private key: ~/.config/sops/age/keys.txt
#   GPG private key: local GPG keyring (fingerprint matches .sops.yaml)
```

## Key Commands

TOPF handles config generation and apply in a single step. Run from `talos/whoverse`:

```bash
topf render              # Render machine configs (preview, no apply)
topf apply               # Apply configs to all nodes (with confirmation)
topf nodes               # List nodes and their state
topf kubeconfig          # Generate admin kubeconfig
topf talosconfig         # Generate talosconfig from secrets bundle
topf upgrade             # Upgrade Talos on all nodes
topf reset               # Reset nodes (destructive!)
talosctl upgrade-k8s     # Upgrade Kubernetes version (TOPF does not do this)
```

## Initial Setup (New Cluster)

1. **Generate cluster secrets** (first time only):
   ```bash
   cd talos/whoverse
   topf secrets generate
   ```
   (This writes `secrets.yaml`, SOPS-encrypted. **Never regenerate for an existing cluster** — it would orphan the trust secrets.)

2. **Bootstrap cluster** (nodes must be in maintenance mode):
   ```bash
   topf apply --auto-bootstrap
   ```

3. **Install Cilium CNI**:
   ```bash
   topf kubeconfig
   just bootstrap-cilium
   ```

4. **Bootstrap FluxCD**:
   ```bash
   just bootstrap
   ```

## Day-2 Operations

### Apply Configuration Changes

After editing `topf.yaml` or any patch file:

```bash
topf render    # Preview the diff
topf apply     # Apply to all nodes (confirmation prompt)
```

### Upgrade Talos / Kubernetes

1. Update `talosVersion` or `kubernetesVersion` in `topf.yaml`
2. Run:
   ```bash
   topf upgrade            # for Talos
   talosctl upgrade-k8s    # for Kubernetes
   ```

## Secrets Management

`secrets.yaml` is encrypted with **age + GPG** (recipient list defined in repo-root `.sops.yaml`). Both recipients can decrypt; adding a recipient never removes existing decrypt capability.

- **Age public key**: `age16865gej0ndnlnghdq347fur59ht8d7wrcfptdw5ja4fhc4lwdfpq59ratl`
- **GPG public key**: `B2266723EDB691FBB16501BC07D6E31CCAE33514`
- **Age private key location**: `~/.config/sops/age/keys.txt`
- **GPG private key location**: local GPG keyring

```bash
# Decrypt secrets (view only)
sops -d secrets.yaml

# Edit secrets (re-encrypts on save)
sops secrets.yaml

# Re-key existing files (after .sops.yaml rules change)
sops updatekeys --yes <file>
```

## Adding a New Cluster

1. Create directory:
   ```bash
   mkdir -p talos/{cluster-name}/{all,control-plane,worker,node}
   ```

2. Copy and modify `topf.yaml` for new cluster

3. Generate secrets:
   ```bash
   cd talos/{cluster-name}
   topf secrets generate
   ```

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
