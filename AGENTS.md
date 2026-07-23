# AGENTS.md - Kubernetes + Talos Repository

This is the primary agent instructions file for the home-ops repository. It covers the Kubernetes infrastructure managed by Flux CD GitOps. For Talos Linux node configuration, see `talos/CLAUDE.md`.

## Prerequisites

Tools are managed via [mise](https://mise.jdx.dev) at the repo root:

```bash
mise install
```

This provides `kubectl`, `helm`, `helmfile`, `flux`, `cilium`, `k9s`, `sops`, `age`, `jq`, `yq`, `just`, and `go`. All versions are pinned in the root `mise.toml`.

## Architecture Overview

- **GitOps Engine**: Flux CD with OCI artifacts (auto-built from GitHub)
- **Resource Composition**: Kustomize layering with Helm charts
- **Helm Charts**: bjw-s app-template for applications
- **Secrets**: External Secrets Operator syncing from 1Password Connect
- **Ingress**: Envoy Gateway with Gateway API HTTPRoutes
  - External Gateway: Cloudflare Tunnel for public access (`*.whoverse.nexus`)
  - Internal Gateway: Tailscale VPN with HA for private access (`*.whoverse.dev`)
- **Networking**: Cilium CNI with BGP, Tailscale operator for VPN LoadBalancer
- **Storage**: ceph-rbd (primary), openebs-hostpath (fallback)

## Directory Structure

### Hierarchy

The Kubernetes directory follows a strict **Group → Namespace → Component → Resources** hierarchy:

```
{group}/
└── {namespace}/
    ├── ns.yaml              # Namespace definition (REQUIRED)
    ├── kustomization.yaml   # K8s Kustomization (references ns.yaml first)
    └── {component}/
        ├── ks.yaml          # Flux Kustomization (metadata.namespace = namespace)
        └── app/             # Resources: helmrelease.yaml, externalsecret.yaml, etc.
```

- **group**: Top-level organizational unit (`apps/`, `infrastructure/`)
- **namespace**: Kubernetes namespace definition (`downloads/`, `entertainment/`, etc.)
- **component**: Single deployed unit (`sonarr-hd/`, `plex/`, `kasm/`)
- **resources**: Actual K8s manifests (`helmrelease.yaml`, etc.)

### File Types

| File | Type | Purpose |
|------|------|---------|
| `ns.yaml` | K8s Namespace | Defines the namespace (at namespace level only) |
| `ks.yaml` | Flux Kustomization | GitOps reconciliation (Flux) |
| `kustomization.yaml` | K8s Kustomization | Resource composition |

### Structure Rules (Enforced by pre-commit hook)

1. `apps/{namespace}/ns.yaml` must exist
2. `apps/{namespace}/kustomization.yaml` must reference `ns.yaml` first
3. No `**/ns.yaml` files outside namespace level (except bootstrap/infrastructure)
4. Component `ks.yaml` `metadata.namespace` must match parent namespace directory

### Validation

```bash
# Run validation
cd kubernetes/scripts && npm run validate

# CI mode (check only, exits non-zero on failure)
npm run validate:check
```

```
kubernetes/
├── apps/                    # Application deployments
│   ├── {namespace}/
│   │   ├── ns.yaml         # Namespace definition
│   │   ├── kustomization.yaml
│   │   └── {component}/
│   │       ├── ks.yaml     # Flux Kustomization
│   │       └── app/        # HelmRelease, ExternalSecret, HTTPRoute, etc.
│   └── kustomization.yaml  # Enable/disable namespace groupings
├── infrastructure/         # Core infrastructure components
│   ├── cert-manager/
│   ├── cnpg-system/
│   ├── external-secrets-system/
│   ├── flux-system/
│   ├── kube-system/
│   ├── monitoring/
│   ├── network/
│   ├── onepassword-connect/
│   └── storage/
├── flux-config/             # Flux CD configuration
├── gateway/                 # Envoy Gateway resources
├── databases/               # CloudNativePG cluster definitions
├── bootstrap/               # Initial cluster setup
└── scripts/                # Validation and deployment scripts
```

## Deployment Workflow

### Production Deployment (GitOps)

Changes are deployed via GitOps workflow:

```bash
# 1. Make changes to kubernetes manifests
# 2. Commit and push to GitHub
git add .
git commit -m "Description of changes"
git push

# 3. OCI artifact is automatically rebuilt by CI/CD
# 4. Trigger Flux to reconcile (optional - Flux polls automatically)
flux reconcile source oci home-ops -n flux-system
flux reconcile kustomization infrastructure -n flux-system
flux reconcile kustomization apps -n flux-system
```

### Development/Testing (Direct Apply)

For faster iteration during development:

```bash
# Apply resources directly
kubectl apply -f path/to/resource.yaml
kubectl apply -k path/to/kustomization/

# Restart Flux-managed resources to pick up changes
kubectl rollout restart deployment/app-name -n namespace

# NOTE: Direct applies are temporary - changes must be committed to git
# for persistence, as Flux will eventually reconcile back to git state
```

### Useful Commands

```bash
# Check Flux status
flux get sources oci -A
flux get kustomizations -A
flux get helmreleases -A

# Force reconciliation
flux reconcile kustomization infrastructure -n flux-system --with-source
flux reconcile kustomization apps -n flux-system --with-source

# Check pod/deployment status
kubectl get pods -A
kubectl get deployments -A
kubectl logs -f deployment/name -n namespace
```

## App Deployment Pattern

Each app follows this structure:

1. **ks.yaml** - Flux Kustomization pointing to app/ directory
2. **app/helmrelease.yaml** - bjw-s app-template HelmRelease
3. **app/externalsecret.yaml** - Vault secret sync (if needed)
4. **app/httproute.yaml** - Gateway API ingress (if needed)
5. **app/kustomization.yaml** - Lists resources to apply

Example HelmRelease structure (bjw-s app-template v4.x):
```yaml
spec:
  chart:
    spec:
      chart: app-template
      version: "4.5.0"
      sourceRef:
        kind: HelmRepository
        name: bjw-s
        namespace: flux-system
  values:
    controllers:
      {app}:
        containers:
          {app}:
            image:
              repository: ...
              tag: ...
            env: ...
    service:
      {app}:
        controller: {app}
        ports:
          http:
            port: ...
    persistence:
      config:
        type: persistentVolumeClaim
        storageClass: ceph-rbd
```

## Adding a New App

1. Create directory structure:
   ```bash
   mkdir -p apps/{category}/{app}/app
   ```

2. Create `ks.yaml` (Flux Kustomization):
   ```yaml
   apiVersion: kustomize.toolkit.fluxcd.io/v1
   kind: Kustomization
   metadata:
     name: {app}
     namespace: {category}
   spec:
     interval: 15m
     path: "./apps/{category}/{app}/app"
     sourceRef:
       kind: OCIRepository
       name: home-ops
       namespace: flux-system
     dependsOn:
       - name: {dependency}  # e.g., {category}-database
     timeout: 10m
     wait: true
     prune: true
   ```

3. Create `app/helmrelease.yaml`, `app/externalsecret.yaml`, `app/httproute.yaml`

4. Create `app/kustomization.yaml`:
   ```yaml
   apiVersion: kustomize.config.k8s.io/v1beta1
   kind: Kustomization
   resources:
     - helmrelease.yaml
     - externalsecret.yaml
     - httproute.yaml
   ```

5. Add app to category's `kustomization.yaml`

6. Deploy changes:
   ```bash
   # For testing: apply directly
   kubectl apply -k apps/{category}/{app}/app

   # For production: commit and push
   git add apps/{category}/{app}
   git commit -m "Add {app} to {category}"
   git push
   ```

## Network Architecture & Ingress

### Overview

The cluster uses **Envoy Gateway** with **Gateway API** for ingress, providing two separate gateways:

- **External Gateway** - Public internet access via Cloudflare Tunnel (`*.whoverse.nexus`)
- **Internal Gateway** - Tailscale VPN access for internal services (`*.whoverse.dev`)

### Envoy Gateway Configuration

**Location:** `infrastructure/network/envoy-gateway/`

Structure:
```
envoy-gateway/
├── ks.yaml                      # Two Kustomizations (app + config)
├── app/helmrelease.yaml         # Envoy Gateway operator
└── config/
    ├── gateway.yaml             # External and Internal Gateways
    ├── envoy-proxy-config.yaml  # LoadBalancer configurations
    └── httproutes/              # Shared HTTPRoutes
```

#### External Gateway (Cloudflare Tunnel)

- **Domain:** `*.whoverse.nexus`
- **Access:** Public internet via Cloudflare Tunnel
- **TLS:** Terminated by Cloudflare
- **Service Type:** ClusterIP (accessed internally by cloudflared)
- **DNS:** External-DNS creates Cloudflare DNS records with proxy enabled

Configuration highlights:
```yaml
# EnvoyProxy: external-proxy-config
spec:
  provider:
    kubernetes:
      envoyService:
        type: ClusterIP

# Gateway: external
metadata:
  annotations:
    external-dns.alpha.kubernetes.io/target: <tunnel-id>.cfargotunnel.com
spec:
  listeners:
    - protocol: HTTP  # Cloudflare handles TLS
      hostname: "*.whoverse.nexus"
```

#### Internal Gateway (Tailscale)

- **Domain:** `*.whoverse.dev`
- **Access:** Tailscale VPN only
- **TLS:** Terminated by Envoy (Let's Encrypt wildcard cert)
- **Service Type:** LoadBalancer with `loadBalancerClass: tailscale`
- **DNS:** External-DNS creates Cloudflare DNS records pointing to Tailscale IP
- **High Availability:** 3 Tailscale proxy replicas with automatic failover

Configuration highlights:
```yaml
# EnvoyProxy: internal-proxy-config
spec:
  provider:
    kubernetes:
      envoyService:
        type: LoadBalancer
        loadBalancerClass: tailscale
        annotations:
          tailscale.com/hostname: whoverse-gateway
          tailscale.com/proxy-group: ingress-proxies

# Gateway: internal
spec:
  listeners:
    - name: http
      protocol: HTTP
      port: 80
      hostname: "*.whoverse.dev"
    - name: https
      protocol: HTTPS
      port: 443
      hostname: "*.whoverse.dev"
      tls:
        certificateRefs:
          - name: whoverse-dev-wildcard-tls
```

### Tailscale Operator

**Location:** `infrastructure/network/tailscale/`

The Tailscale Kubernetes operator provides:
- LoadBalancer service integration via `loadBalancerClass: tailscale`
- ProxyGroup for high-availability ingress
- Automatic Tailscale Service creation and management

Structure:
```
tailscale/
├── ks.yaml                     # Two Kustomizations (app + config)
├── app/
│   ├── helmrelease.yaml        # Tailscale operator (v1.90.9+)
│   ├── externalsecret.yaml     # OAuth credentials from 1Password
│   └── kustomization.yaml
└── config/
    ├── proxygroup.yaml         # HA proxy configuration
    └── kustomization.yaml
```

#### OAuth Configuration

OAuth credentials are stored in 1Password (`tailscale-k8s-operator`) and synced via ExternalSecret:

```yaml
# externalsecret.yaml
spec:
  secretStoreRef:
    kind: ClusterSecretStore
    name: onepassword-connect
  data:
    - secretKey: client_id
      remoteRef:
        key: tailscale-k8s-operator
        property: username
    - secretKey: client_secret
      remoteRef:
        key: tailscale-k8s-operator
        property: credential

# helmrelease.yaml
values:
  oauthSecretVolume:
    secret:
      secretName: tailscale-operator-oauth
```

**Required OAuth Scopes:**
- Devices Core (write)
- Auth Keys (write)
- Services (write) - Required for ProxyGroup HA

#### ProxyGroup (High Availability)

The ProxyGroup creates 3 Tailscale proxy replicas for zero-downtime failover:

```yaml
# config/proxygroup.yaml
apiVersion: tailscale.com/v1alpha1
kind: ProxyGroup
metadata:
  name: ingress-proxies
  namespace: network
spec:
  type: ingress
  replicas: 3
```

Features:
- **Automatic Failover:** Tailscale Services feature load balances across all replicas
- **Zero Downtime:** Service remains available during pod restarts/updates
- **Single Hostname:** All replicas advertise the same `whoverse-gateway` hostname
- **Health Checking:** Unhealthy replicas are automatically removed from rotation

Status check:
```bash
kubectl get proxygroup ingress-proxies -n network
kubectl get pods -n network | grep ingress-proxies
```

#### Cilium Integration

**Important:** Cilium must be configured with socket load balancer bypass for Tailscale compatibility:

```yaml
# infrastructure/kube-system/cilium/app/helmrelease.yaml
values:
  socketLB:
    enabled: true
    hostNamespaceOnly: true
```

This prevents Cilium's socket-level load balancing from bypassing Tailscale's firewall rules.

#### Pod Security

The network namespace requires privileged pod security for Tailscale pods:

```yaml
# infrastructure/network/ns.yaml
metadata:
  labels:
    pod-security.kubernetes.io/enforce: privileged
```

### External-DNS Configuration

**Location:** `infrastructure/network/external-dns/`

Two External-DNS instances manage different domains:

#### external-dns-nexus (Public)
- **Domain:** `whoverse.nexus`
- **Provider:** Cloudflare
- **Proxied:** Yes (CDN enabled)
- **Sources:** Gateway HTTPRoutes
- **Target:** Cloudflare Tunnel

#### external-dns-dev (Internal)
- **Domain:** `whoverse.dev`
- **Provider:** Cloudflare
- **Proxied:** No (DNS-only)
- **Sources:** Gateway HTTPRoutes
- **Behavior:** Creates specific A records that override wildcard

**DNS Priority Behavior:**
```
*.whoverse.dev           → Wildcard catchall (points elsewhere)
files.whoverse.dev       → Specific record (points to Tailscale IP, overrides wildcard)
app.whoverse.dev         → Specific record (points to Tailscale IP, overrides wildcard)
unmapped.whoverse.dev    → Uses wildcard catchall
```

External-DNS automatically creates DNS records for any HTTPRoute attached to the internal Gateway:
```bash
# External-DNS watches HTTPRoutes and creates A records
# Example: files.whoverse.dev → 100.90.188.172 (Tailscale IP)
```

### Creating HTTPRoutes

HTTPRoutes define how traffic is routed to services. They can be:
- **Per-app:** Located in `apps/{category}/{app}/app/httproute.yaml`
- **Shared:** Located in `infrastructure/network/envoy-gateway/config/httproutes/`

Example HTTPRoute for internal access:
```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: app-internal
  namespace: app-namespace
spec:
  parentRefs:
    - name: internal           # Attach to internal gateway
      namespace: network
      sectionName: https       # Use HTTPS listener
  hostnames:
    - app.whoverse.dev
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: app-service
          port: 80
```

For dual access (both internal and external):
```yaml
spec:
  parentRefs:
    - name: internal
      namespace: network
      sectionName: https
    - name: external
      namespace: network
      sectionName: http
  hostnames:
    - app.whoverse.dev     # Internal
    - app.whoverse.nexus   # External
```

### Troubleshooting Network Issues

```bash
# Check Gateway status
kubectl get gateway -n network
kubectl describe gateway internal -n network

# Check EnvoyProxy configuration
kubectl get envoyproxy -n network
kubectl describe envoyproxy internal-proxy-config -n network

# Check Tailscale service
kubectl get svc envoy-internal -n network
# Should show EXTERNAL-IP as Tailscale IP (100.x.x.x)

# Check ProxyGroup and proxy pods
kubectl get proxygroup ingress-proxies -n network
kubectl get pods -n network | grep ingress-proxies
kubectl logs -n network ingress-proxies-0 -c tailscale

# Check Tailscale operator
kubectl get pods -n network -l app=operator
kubectl logs -n network -l app=operator

# Check HTTPRoute status
kubectl get httproute -n namespace app-name -o yaml
kubectl describe httproute -n namespace app-name

# Check External-DNS
kubectl logs -n network -l app.kubernetes.io/name=external-dns-dev
kubectl logs -n network -l app.kubernetes.io/name=external-dns-nexus

# Verify DNS records
dig app.whoverse.dev
dig app.whoverse.nexus

# Check certificate
kubectl get certificate -n network whoverse-dev-wildcard-tls
kubectl describe certificate -n network whoverse-dev-wildcard-tls
```

## Secrets Management

Secrets are managed via External Secrets Operator syncing from 1Password or Vault:

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: {app}-config
  namespace: {namespace}
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: vault
  target:
    name: {app}-config
  data:
    - secretKey: {key}
      remoteRef:
        key: {vault-path}
        property: {property}
```

## Storage Classes

- **ceph-rbd**: Distributed block storage (recommended for most apps)
- **openebs-hostpath**: Local node storage (faster, not replicated)

## Troubleshooting

```bash
# Check Flux kustomizations
kubectl get kustomizations -n flux-system

# Check HelmReleases
kubectl get helmreleases -A

# View app logs
kubectl logs -f deployment/{app} -n {namespace}

# Check pod status
kubectl get pods -n {namespace}

# Describe failing pod
kubectl describe pod {pod-name} -n {namespace}

# Check HTTPRoute status
kubectl get httproute -n {namespace}

# Force Flux reconciliation
flux reconcile kustomization apps -n flux-system
```

## Cilium CA and Hubble TLS

This repo does **not** include the Cilium CA certificate/private key or the Hubble server TLS pair. Both are cluster-specific secrets that must be generated during initial cluster setup and applied before Cilium starts.

### Generate Cilium CA

```bash
# Generate a 4096-bit RSA CA key valid for 10 years
openssl genrsa -out cilium-ca.key 4096
openssl req -x509 -new -nodes -key cilium-ca.key -sha256 -days 3650 \
  -subj "/CN=Cilium CA" \
  -out cilium-ca.crt

# Create the cilium-ca Kubernetes secret
kubectl create namespace kube-system --dry-run=client -o yaml | kubectl apply -f -
kubectl -n kube-system create secret generic cilium-ca \
  --from-file=ca.crt=cilium-ca.crt \
  --from-file=ca.key=cilium-ca.key
```

### Generate Hubble server TLS

```bash
# Hubble server cert signed by the Cilium CA
openssl genrsa -out hubble-server.key 4096
openssl req -new -key hubble-server.key -subj "/CN=hubble-server" -out hubble-server.csr
openssl x509 -req -in hubble-server.csr -CA cilium-ca.crt -CAkey cilium-ca.key \
  -CAcreateserial -out hubble-server.crt -days 3650 -sha256 \
  -extfile <(echo "subjectAltName=DNS:hubble.kube-system.svc")

kubectl -n kube-system create secret tls hubble-server-certs \
  --cert=hubble-server.crt --key=hubble-server.key
```

### Patch Cilium manifests

These secrets are referenced by the Cilium HelmRelease's inline manifests (`cilium-install.yaml`, `cilium-inline.yaml`, `patches/cilium-manifests.yaml`). When forking this repo, generate those manifests locally:

```bash
cd talos/whoverse
./gen-cilium-manifest.sh   # renders cilium-install.yaml + cilium-inline.yaml
# edit patches/cilium-manifests.yaml inlineManifests section with your secrets
```

Do **not** commit the generated manifests to a public repo — they contain your cluster's private keys.
