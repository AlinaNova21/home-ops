---
name: home-ops-network-troubleshooting
description: Use when diagnosing network/ingress issues in home-ops - Gateway/Tailscale/ExternalDNS/cert diagnostics, HTTPRoute verification, EnvoyProxy checks, ProxyGroup health
---

# Network Troubleshooting

Two gateways:
- **internal** — Tailscale (`*.whoverse.dev`)
- **external** — Cloudflare Tunnel (`*.whoverse.nexus`)

## Gateway / Envoy

```bash
# Gateway status
kubectl get gateway -n network
kubectl describe gateway internal -n network
kubectl describe gateway external -n network

# EnvoyProxy configuration
kubectl get envoyproxy -n network
kubectl describe envoyproxy internal-proxy-config -n network
kubectl describe envoyproxy external-proxy-config -n network
```

## Tailscale

```bash
# Service should show EXTERNAL-IP as 100.x.x.x
kubectl get svc envoy-internal -n network

# ProxyGroup + replica pods
kubectl get proxygroup ingress-proxies -n network
kubectl get pods -n network -l app.kubernetes.io/name=tailscale

# Per-pod logs (replica name: ingress-proxies-0/1/2)
kubectl logs -n network ingress-proxies-0 -c tailscale

# Operator logs
kubectl get pods -n network -l app=operator
kubectl logs -n network -l app=operator
```

## HTTPRoute

```bash
# Status
kubectl get httproute -A
kubectl describe httproute -n {namespace} {name}

# Full YAML (look at status.parents[].conditions)
kubectl get httproute -n {namespace} {name} -o yaml
```

## External-DNS

```bash
# Two deployments: external-dns-nexus (proxied) + external-dns-dev (DNS-only)
kubectl logs -n network -l app.kubernetes.io/name=external-dns-dev
kubectl logs -n network -l app.kubernetes.io/name=external-dns-nexus

# Verify actual records
dig {app}.whoverse.dev
dig {app}.whoverse.nexus
```

## TLS / Certificates

```bash
# Internal gateway cert (Let's Encrypt wildcard)
kubectl get certificate -n network whoverse-dev-wildcard-tls
kubectl describe certificate -n network whoverse-dev-wildcard-tls

# cert-manager logs
kubectl logs -n cert-manager -l app.kubernetes.io/name=cert-manager
```

## Cilium / Tailscale interaction

If Tailscale proxies can't reach backend services, check Cilium socketLB bypass:

```bash
# Must be enabled with hostNamespaceOnly
kubectl get cm cilium-config -n kube-system -o yaml | grep -A1 socketLB
```

## DNS priority behavior

```
*.whoverse.dev           → wildcard catchall (points elsewhere)
files.whoverse.dev       → specific record (Tailscale IP, overrides wildcard)
app.whoverse.dev         → specific record (Tailscale IP, overrides wildcard)
unmapped.whoverse.dev    → uses wildcard catchall
```

## Common failure modes

| Symptom | Check |
|---|---|
| `502 Bad Gateway` from external | `kubectl logs -n network -l app.kubernetes.io/name=external-dns-nexus` for tunnel token issues |
| `connection refused` on internal | `kubectl get svc envoy-internal -n network` EXTERNAL-IP must be 100.x |
| HTTPRoute `Accepted: False` | `kubectl describe httproute` → check parentRefs and listener section |
| DNS not resolving | `dig` to confirm record exists; check external-dns logs for rate-limit / API token errors |
| Cert not issuing | `kubectl describe certificate` → check ACME challenge and cert-manager logs |
