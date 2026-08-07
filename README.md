# whoverse — home Kubernetes cluster

A self-hosted Kubernetes cluster running on low-power x86 hardware, managed entirely as code with GitOps. All infrastructure in this repository is reconciled by [Flux](https://fluxcd.io/) — no manual `kubectl` apply, everything is defined in manifests.

## Hardware

Five-node [Talos Linux](https://www.talos.dev/) cluster:

| Node | Role | Hardware | CPU | Cores | RAM |
|---|---|---|---|---|---|
| cp1 | Control plane | ZimaBoard | Intel Celeron N3450 @ 1.10GHz | 4C | 8GB |
| cp2 | Control plane | ZimaBoard | Intel Celeron N3450 @ 1.10GHz | 4C | 8GB |
| cp3 | Control plane | ZimaBoard | Intel Celeron N3450 @ 1.10GHz | 4C | 8GB |
| w1 | Worker | ZimaBoard 2 | Intel N150 | 4C | 16GB |
| w2 | Worker | VM (libvirt) | QEMU virtual | 4 vCPU | 8GB |

Storage: [miroir](https://github.com/home-operations/miroir) replicated LVM-thin CSI pool (128GiB on CPs/W1, 32GiB on W2).

## Core Infrastructure

### Cluster Foundation

| Component | Role |
|---|---|
| [Talos Linux](https://www.talos.dev/) | Immutable Kubernetes OS |
| [Kubernetes](https://kubernetes.io/) | Container orchestration |
| [Flux CD](https://fluxcd.io/) | GitOps delivery (Flux Operator) |

### Networking

| Component | Role |
|---|---|
| [Cilium](https://cilium.io/) | CNI, BGP routing, network policy |
| [Envoy Gateway](https://gateway.envoyproxy.io/) | Gateway API ingress |
| [Cloudflare Tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/) | External ingress |
| [Tailscale](https://tailscale.com/) | Private VPN access |
| [ExternalDNS](https://github.com/kubernetes-sigs/external-dns) | Cloudflare DNS records |

### Security

| Component | Role |
|---|---|
| [cert-manager](https://cert-manager.io/) | TLS certificates (Cloudflare Origin CA) |
| [External Secrets Operator](https://external-secrets.io/) | Secret sync from 1Password Connect |
| [1Password Connect](https://developer.1password.com/docs/connect/) | Secrets backend |
| [KGuardian](https://kguardian.dev/) | Kubernetes security platform |

### Storage & Registry

| Component | Role |
|---|---|
| [miroir](https://github.com/home-operations/miroir) | Replicated CSI storage (LVM-thin) |
| [zot](https://zotregistry.dev/) | OCI container registry |
| [Spegel](https://spegel.dev/) | Peer-to-peer image distribution |

### Observability & Notifications

| Component | Role |
|---|---|
| [VictoriaMetrics](https://victoriametrics.com/) | Metrics collection + storage |
| [Grafana](https://grafana.com/) | Dashboards |
| [ntfy](https://ntfy.sh/) | Notifications / alerting |

### Operations

| Component | Role |
|---|---|
| [Reloader](https://github.com/stakater/Reloader) | Config-reload automation |
| [Kopiur](https://github.com/home-operations/kopiur) | Kopia-based backups |
| [KubeVirt](https://kubevirt.io/) | VM workloads on Kubernetes |
| [Headlamp](https://headlamp.dev/) | Cluster dashboard |
