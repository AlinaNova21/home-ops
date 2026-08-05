---
name: home-ops-create-httproute
description: Use when creating an HTTPRoute resource for Gateway API ingress in home-ops - covers per-app routing, dual gateway access (internal + external), listener scoping, and shared routes
---

# Creating HTTPRoutes

HTTPRoutes define how traffic flows from Envoy Gateway to a Kubernetes Service. Two gateways exist, both **HTTPS**:

- **`internal`** (Tailscale, `*.whoverse.dev`, listener `https`) — internal/LAN access
- **`external`** (Cloudflare Tunnel, listener `whoverse-nexus` for `*.whoverse.nexus`, listener `beee-gay` for `*.beee.gay`) — public access; TLS terminated at origin with Cloudflare Origin CA certs

## File location

- **Per-app**: `kubernetes/{namespace}/{component}/app/httproute.yaml`
- **Shared**: `kubernetes/network/envoy-gateway/config/httproutes/`

## Default convention — name-only parentRefs

The standard pattern is `parentRefs` by gateway name **without `sectionName`** (hostname matching routes traffic to the right listener). The `{app}` in `backendRefs` is the bjw-s app-template service name — which equals the HelmRelease/controller name.

### Internal-only

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: {app}-internal
  namespace: {app-namespace}
spec:
  parentRefs:
    - name: internal
      namespace: network
  hostnames:
    - {app}.whoverse.dev
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: {app}
          port: 80
```

### External-only

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: {app}-external
  namespace: {app-namespace}
spec:
  parentRefs:
    - name: external
      namespace: network
  hostnames:
    - {app}.whoverse.nexus   # or {app}.beee.gay for the second public domain
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: {app}
          port: 80
```

### Dual access (both internal and external)

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: {app}
  namespace: {app-namespace}
spec:
  parentRefs:
    - name: internal
      namespace: network
    - name: external
      namespace: network
  hostnames:
    - {app}.whoverse.dev     # Internal
    - {app}.whoverse.nexus   # External
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: {app}
          port: 80
```

## When to scope with `sectionName`

`sectionName` is only needed to bind a route to a **specific listener**. Current usage is limited to explicit scoping on the internal gateway's `https` listener (e.g. `monitoring/victoria-metrics` routes for `alerts.whoverse.dev` / `vmalert.whoverse.dev`):

```yaml
  parentRefs:
    - name: internal
      namespace: network
      sectionName: https
```

Do **not** use `sectionName: http` — the external gateway no longer has an HTTP listener (TLS is terminated at origin).

## DNS behavior

External-DNS watches HTTPRoutes attached to either gateway and creates the appropriate DNS records:

- `*.whoverse.dev` → A record pointing to Tailscale IP (DNS-only)
- `*.whoverse.nexus` → Cloudflare proxy (CDN enabled)
- `*.beee.gay` → Cloudflare proxy

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
