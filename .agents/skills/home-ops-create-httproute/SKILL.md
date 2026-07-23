---
name: home-ops-create-httproute
description: Use when creating an HTTPRoute resource for Gateway API ingress in home-ops - covers per-app routing, dual gateway access (internal + external), shared routes, and gateway references
---

# Creating HTTPRoutes

HTTPRoutes define how traffic flows from Envoy Gateway to a Kubernetes Service. Two gateways exist:

- **`internal`** (Tailscale, `*.whoverse.dev`, section `https`) — internal/LAN access
- **`external`** (Cloudflare Tunnel, `*.whoverse.nexus`, section `http`) — public access

## File location

- **Per-app**: `kubernetes/apps/{namespace}/{component}/app/httproute.yaml`
- **Shared**: `kubernetes/infrastructure/network/envoy-gateway/config/httproutes/`

## Internal-only HTTPRoute

```yaml
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: {app}-internal
  namespace: {app-namespace}
spec:
  parentRefs:
    - name: internal
      namespace: network
      sectionName: https   # HTTPS listener
  hostnames:
    - {app}.whoverse.dev
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: {app}-service
          port: 80
```

## External-only HTTPRoute

```yaml
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: {app}-external
  namespace: {app-namespace}
spec:
  parentRefs:
    - name: external
      namespace: network
      sectionName: http    # Cloudflare handles TLS
  hostnames:
    - {app}.whoverse.nexus
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: {app}-service
          port: 80
```

## Dual access (both internal and external)

```yaml
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: {app}
  namespace: {app-namespace}
spec:
  parentRefs:
    - name: internal
      namespace: network
      sectionName: https
    - name: external
      namespace: network
      sectionName: http
  hostnames:
    - {app}.whoverse.dev     # Internal
    - {app}.whoverse.nexus   # External
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: {app}-service
          port: 80
```

## DNS behavior

External-DNS watches HTTPRoutes attached to either gateway and creates the appropriate DNS records:

- `*.whoverse.dev` → A record pointing to Tailscale IP (DNS-only)
- `*.whoverse.nexus` → Cloudflare proxy (CDN enabled)

If a specific record exists (`app.whoverse.dev`), it overrides the wildcard catchall.

## Verification

After applying:

```bash
kubectl get httproute -n {app-namespace}
kubectl describe httproute -n {app-namespace} {app}
dig {app}.whoverse.dev
dig {app}.whoverse.nexus
```

See `home-ops-network-troubleshooting` for diagnostic flows.
