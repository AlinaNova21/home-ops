# Talos Kubernetes Clusters

This directory contains Talos Linux cluster configurations managed by [talhelper](https://github.com/budimanjojo/talhelper).

## Directory Structure

```
talos/
├── whoverse/              # Primary cluster
│   ├── talconfig.yaml     # Cluster configuration
│   ├── talsecret.sops.yaml # Encrypted secrets (generated)
│   ├── patches/           # Machine config patches
│   └── clusterconfig/     # Generated configs (gitignored)
└── README.md
```

## Prerequisites

Tools are managed via [mise](https://mise.jdx.dev) at the repo root:

```bash
mise install
```

This provides `talosctl`, `talhelper`, `sops`, `age`, `kubectl`, `cilium`, `jq`, and `yq`. All versions are pinned in the root `mise.toml`.

## Cluster: whoverse

| Property | Value |
|----------|-------|
| Nodes | 3 mixed controlplane |
| IPs | 192.168.2.21-23 |
| VIP | 192.168.2.20 |
| CNI | Cilium |
| Talos | v1.11.5 |
| Kubernetes | v1.34.1 |

### Initial Setup

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
just talos-cilium
```

5. **Bootstrap FluxCD**:

```bash
just bootstrap
```

### Day-2 Operations

**Apply configuration changes**:
```bash
just talos-gen
just talos-apply
```

**Check cluster health**:
```bash
just talos-health
```

**Update kubeconfig**:
```bash
just talos-kubeconfig
```

## Secrets Management

Secrets are encrypted with SOPS using:
- **Age key**: `age16865gej0ndnlnghdq347fur59ht8d7wrcfptdw5ja4fhc4lwdfpq59ratl`
- **GPG key**: `B2266723EDB691FBB16501BC07D6E31CCAE33514`

The age private key is stored at `~/.config/sops/age/keys.txt`.

To decrypt secrets:
```bash
sops -d talsecret.sops.yaml
```

To edit secrets:
```bash
sops talsecret.sops.yaml
```

## Adding a New Cluster

1. Create directory: `mkdir -p talos/[cluster-name]/patches`
2. Copy and modify `talconfig.yaml`
3. Generate secrets: `talhelper gensecret > talsecret.sops.yaml && sops -e -i talsecret.sops.yaml`
4. Add Justfile recipes for the new cluster
