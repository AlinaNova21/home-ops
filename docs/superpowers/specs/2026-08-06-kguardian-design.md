# Deploy kguardian to the `security` namespace

- **Date:** 2026-08-06
- **Status:** Draft, pending user review
- **Owner:** home-ops maintainers

## 1. Problem

The cluster runs a mostly policy-open posture: Cilium is the CNI but only one
NetworkPolicy exists in the entire tree (`flux-system/webhook`), and there are
no seccomp profiles beyond the Talos default. Hand-authoring least-privilege
NetworkPolicies / CiliumNetworkPolicies / seccomp profiles for every workload
is slow and error-prone.

kguardian ([docs](https://docs.kguardian.dev/quickstart)) observes pod traffic
and syscalls with an eBPF controller DaemonSet, stores observations in a
bundled PostgreSQL, and then **generates** Kubernetes NetworkPolicies,
CiliumNetworkPolicies, and seccomp profiles from observed runtime behavior —
no hand-authored rules. It also ships an audit-mode evaluator that reports
"Would-Deny / Allow" verdicts so policies can be validated in audit mode before
enforcement.

## 2. Goal

Deploy kguardian as a GitOps-managed app so it can start learning the
cluster's runtime behavior and producing policy artifacts. Also stand up its
monitoring (metrics scrape + dashboard) so the security stack is observable
from day one.

The `security` namespace is intentionally created fresh — trivy-operator (and
other security tooling) will land there later, keeping security workloads
isolated from the mixed `network` namespace.

## 3. Prerequisites check

| Requirement | Status |
|---|---|
| Linux kernel 6.2+ (eBPF CO-RE) | ✅ Talos v1.13.5 → kernel 6.12 |
| containerd runtime | ✅ Talos default; socket `/run/containerd/containerd.sock` matches chart default |
| Privileged PSA for controller | ✅ New `security` namespace gets `pod-security.kubernetes.io/enforce: privileged` (mirrors `network`) |
| OCI chart | ✅ `oci://ghcr.io/kguardian-dev/charts/kguardian`, latest `chart/v1.17.1` |

Notes:
- Chart is **not cosign-signed** → OCIRepository omits the `verify:` block
  (unlike the bjw-s app-template pattern).
- No external/managed Postgres or CNPG operator exists in the cluster → bundled
  database is the only realistic option.

## 4. Architecture

Single HelmRelease installs the full stack in `security`:

| Component | Kind | Notes |
|---|---|---|
| `kguardian-controller` | DaemonSet | privileged, eBPF + containerd socket, one per node; control-plane toleration included in chart defaults |
| `kguardian-broker` | Deployment | REST API :9090; Postgres-backed telemetry; `/metrics` + ServiceMonitor |
| `kguardian-db` | Deployment + PVC | bundled PostgreSQL 18, 10Gi on `miroir-replicated` |
| `kguardian-evaluator` | Deployment | audit-mode would-deny/allow matcher — **kept enabled** (default) |
| `kguardian-frontend` | Deployment | UI :5173, talks to broker directly from the browser |
| `llm-bridge` (AI assistant) | Deployment | **not deployed** — `ai.enabled: false` (default); no LLM provider key wired |

Deliberate exclusions (documented for later):

- **No kopiur backup** for the DB PVC — telemetry is derived/relearnable; the
  broker retains audit verdicts 30 days by default (`broker.audit.retention`).
  If audit history ever becomes valuable, add the `kopiur/backup` component
  later (component name must equal `APP` substitute = `kguardian`).
- **No broker ingress NetworkPolicy opt-in** (`broker.networkPolicy.enabled`)
  — the cluster is policy-open by design today, and the opt-in requires
  `allowedNodeCIDRs: [192.168.2.0/24]` with a coarse-allow caveat on Cilium.
  Revisit once kguardian-generated policies start landing.
- **No Security Profiles Operator** — seccomp profile distribution to nodes
  (`/var/lib/kubelet/seccomp/`) is the user's job today; SPO is a follow-up
  decision.
- **No AI assistant** — `llm-bridge` stays off until a provider/API-key choice
  is made (would arrive as one ExternalSecret + small values block).

## 5. File layout

```
kubernetes/security/
├── ns.yaml                    # privileged PSA, infrastructure label
├── kustomization.yaml         # ns.yaml + kguardian/ks.yaml
└── kguardian/
    ├── ks.yaml                # Flux Kustomization, namespace=security, no kopiur component
    └── app/
        ├── kustomization.yaml # ocirepository + helmrelease + httproute
        ├── ocirepository.yaml # oci://ghcr.io/kguardian-dev/charts/kguardian
        ├── helmrelease.yaml
        └── httproute.yaml     # kguardian.whoverse.dev, internal gateway
```

Plus:
- `kubernetes/kustomization.yaml` aggregator: add `security` entry.
- `kubernetes/monitoring/grafana/app/folders.yaml`: add `security` GrafanaFolder.
- `kubernetes/monitoring/grafana/app/dashboards/kguardian.yaml`: new
  GrafanaDashboard; register in `kubernetes/monitoring/grafana/app/kustomization.yaml`.

## 6. Key manifests

### 6.1 `ns.yaml`

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: security
  labels:
    homelab.whoverse.dev/component: infrastructure
    pod-security.kubernetes.io/enforce: privileged
```

### 6.2 `ks.yaml`

Flux Kustomization following the cloudflared shape:

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: kguardian
  namespace: security
spec:
  interval: 30m
  path: "./kubernetes/security/kguardian/app"
  sourceRef:
    kind: GitRepository
    name: home-ops
    namespace: flux-system
  timeout: 10m
  wait: true
  prune: true
```

No `components: kopiur/backup` (no PVC backup), no `postBuild.substitute` (no
kopiur placeholders).

### 6.3 `ocirepository.yaml`

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: OCIRepository
metadata:
  name: kguardian
  namespace: security
spec:
  interval: 1h
  layerSelector:
    mediaType: application/vnd.cncf.helm.chart.content.v1.tar+gzip
    operation: copy
  ref:
    tag: "chart/v1.17.1"
    digest: sha256:...   # resolve via crane at implementation time
  url: oci://ghcr.io/kguardian-dev/charts/kguardian
```

No `verify:` block — chart is not signed.

### 6.4 `helmrelease.yaml` — values summary

```yaml
chartRef:
  kind: OCIRepository
  name: kguardian
  namespace: security
values:
  database:
    enabled: true
    persistence:
      enabled: true
      size: 10Gi
      storageClassName: miroir-replicated
  evaluator:
    enabled: true          # default; explicit for clarity
  ai:
    enabled: false         # default; explicit for clarity
  broker:
    metrics:
      serviceMonitor:
        enabled: true      # vmagent auto-converts ServiceMonitors (selectAllByDefault)
  frontend:
    ingress:
      enabled: false       # HTTPRoute is the ingress; chart ingress unused
```

Controller defaults are fine for Talos: containerd socket + bundle path match,
control-plane `NoSchedule` tolerated, excluded namespaces default
(`kguardian`, `kube-system`).

### 6.5 `httproute.yaml`

Internal-only route on the Tailscale gateway:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: kguardian
  namespace: security
spec:
  parentRefs:
    - name: internal          # confirm exact internal gateway name at implementation
      namespace: network
  hostnames:
    - kguardian.whoverse.dev
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: kguardian-frontend   # confirm service name/port from chart templates
          port: 5173
```

**Security rationale:** broker API is unauthenticated and the frontend calls it
from the browser; internal-only exposure (Tailscale `*.whoverse.dev`) is
required. External (Cloudflare) exposure is out of scope until an
authenticating proxy (Dex/Envoy SecurityPolicy) exists in front of it.

### 6.6 Monitoring

- **Scrape:** `broker.metrics.serviceMonitor.enabled: true` — the chart emits a
  plain ServiceMonitor; vmagent (`selectAllByDefault: true`) auto-converts and
  scrapes it. No `VMPodScrape` needed.
- **Dashboard:** hand-authored `GrafanaDashboard` `kguardian` (no official
  kguardian dashboard exists yet) in a new `security` GrafanaFolder, mapping
  `DS_PROMETHEUS` → VictoriaMetrics per existing dashboard pattern. Covers the
  seven broker gauges:
  `broker_db_schema_ready`, `broker_db_reachable`, `broker_audit_enabled`,
  `broker_audit_inflight_available`, `broker_db_pool_idle`, `broker_db_pool_max`,
  `broker_uptime_seconds`.

## 7. Rollout / post-deploy

1. Worktree `feat/kguardian` (this branch), baseline `flate-test` green (186
   passed).
2. Author manifests → `just flate-test` + `pre-commit run --all-files` gates.
3. Commit + push + PR; Flux reconciles on merge.
4. Post-deploy (manual, workstation):
   - Install `kubectl-kguardian` CLI (`advisor/v1.6.1` release assets) for
     policy generation via broker port-forward.
   - Let workloads run 5–15 min for observation, then
     `kubectl kguardian gen networkpolicy <pod> -n <ns>` (dry-run default)
     and iterate with audit-mode before enforcing anything.

## 8. Open items (resolve at implementation)

- Chart `chart/v1.17.1` OCI digest (via `crane digest`).
- Internal gateway `parentRefs` name (expect `internal` in `network`, confirm
  against an existing internal-only HTTPRoute).
- `kguardian-frontend` Service name/port as rendered by the chart (confirm
  against chart templates; docs say 5173).
- Exact dashboard panel set for the seven broker gauges.

## 9. Future work (explicitly out of scope)

- trivy-operator into `security` (the reason the namespace exists).
- Security Profiles Operator for seccomp profile distribution.
- Broker ingress NetworkPolicy once the cluster moves toward enforcement.
- AI assistant (`llm-bridge`) + provider key.
- kopiur backup of the DB PVC.
