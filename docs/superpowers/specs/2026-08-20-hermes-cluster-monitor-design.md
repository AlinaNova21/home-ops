# Design: Hermes Cluster Monitor

**Date:** 2026-08-20
**Status:** Draft for review

## Summary

Deploy a **Hermes Agent** instance inside the Kubernetes cluster, dedicated to
monitoring the cluster. It replaces the (already disabled) Robusta **Holmes**
agent — the stale `kubernetes/holmes/` directory is scheduled for cleanup.

Unlike the moltbot deployment (raw `hermes-cli` toolset with shell access via
its own user), the cluster copy gets **no raw `kubectl` access**. All cluster
authority is mediated through **MCP servers**, each carrying its own narrowly
scoped ServiceAccount, so the agent can be constrained per-tool at the MCP
boundary rather than through a broad kubectl toolset.

Primary operating mode is a **proactive watchdog** (scheduled health checks via
Hermes cron/kanban), with interactive chat (built-in Hermes dashboard), autonomous
T2-lite remediation, and alert notifications routed to ntfy. Per-alert agent
activation (chaski → agent webhook) is deliberately **dropped** to avoid
spawning slow sessions on frequent alerts.

## Goals / Non-Goals

### Goals
- Run a Hermes Agent in-cluster that monitors cluster health (watchdog-led).
- Explicit, easily-auditable cluster access through MCP servers, not raw kubectl.
- Secret data is **never** readable by the agent (hard RBAC + `--mask-secrets`).
- Agent **cannot modify itself** (own Deployment/SA/RBAC/config/code) — enforced
  by RBAC, GitOps drift-correction, Hermes file-write safety, and approval rules.
- Self-hosted web stack (SearXNG + trafilatura local-extract) and shared memini
  memory via a single Tailscale egress to moltbot.

### Non-Goals
- Alert-driven per-webhook agent activation (dropped; alerts go to ntfy).
- Open WebUI frontend in v1 (deferred; built-in Hermes dashboard first, Open
  WebUI can be added later via Hermes's OpenAI-compatible API server).
- Full cluster-admin authority (T3).

## Architecture

```
                              ┌────────────────────────────────────────────┐
   browser (tailscale) ──────▶│ hermes (Deployment)   [gVisor]            │
   hermes.whoverse.dev        │  - built-in dashboard/webui (interactive) │
                              │  - cron/kanban watchdog (primary mode B)  │
                              │  - model: OpenRouter DeepSeek (0731)      │
                              │  - memory.provider: memini (shared)       │
   ntfy (notifications ns) ◀──│  - ntfy toolset (outbound pushes)         │
   └─ watchdog alerts/pushes  └──────────────┬────────────────────────────┘
        moltbot-egress ─memini:8081──────────┤  (network/ Tailscale egress)
   moltbot memini ◀──────────────────────────┘
                              │ MCP (hermes mcp add)
                              ▼
   ┌───────────────┐        ┌───────────────────────┐      ┌─────────────────┐
   │ flux-operator │        │ konflate (existing,   │      │ network/        │
   │ -mcp (Deploy) │        │  default ns) MCP      │      │ moltbot-egress  │
   │  [gVisor]     │◀───────┤  http://konflate...   │      │  Tailscale      │
   │  --mask-secrets│       └─────────────────────┘      │  moltbot:8080    │
   │  scoped SA RBAC│                                    │  moltbot:8081    │
   └───────────────┘                                    └─────────────────┘
```

### Components (all in new `hermes` namespace unless noted)

1. **`hermes` Deployment** — the Hermes Agent, official published image
   **`nousresearch/hermes-agent`**, command `gateway run` (s6-overlay supervises
   the gateway + dashboard). `HERMES_HOME=/opt/data`. gVisor runtime class
   (`gvisor`). The published image's `/opt/hermes` install tree is immutable
   (root-owned, read-only to the runtime `hermes` UID 10000); the container
   starts PID 1 as root (s6) to seed/chown `/opt/data`, then drops to `hermes`.
2. **`flux-operator-mcp` Deployment** (separate) — carries all cluster
   authority via its own ServiceAccount. gVisor. Flags: `--mask-secrets`.
3. **konflate MCP** — existing `default/konflate` app (`mcp: true`); serves a
   read-only streamable-HTTP MCP at
   `http://konflate.default.svc.cluster.local:8080/mcp` (`list_pull_requests`,
   `get_pr_summary`, `get_pr_diff`). Hermes adds it as an MCP server; no new
   workload.
4. **`network/moltbot-egress`** — Tailscale egress Service (ExternalName +
   `tailscale.com` annotations + egress ProxyGroup) exposing two ports to
   moltbot: **8080** (SearXNG) and **8081** (memini). Modeled on `pve-egress`.
5. **HTTPRoute** — built-in Hermes dashboard at `hermes.whoverse.dev`
   (internal Tailscale gateway only; **not** on the external Cloudflare gateway).
   Dashboard binds `0.0.0.0` (`HERMES_DASHBOARD=1`) and therefore requires an
   auth provider (serve behind the internal gateway using
   `HERMES_DASHBOARD_BASIC_AUTH_USERNAME`/`_PASSWORD`, or bind loopback + proxy)
   — the published image fails closed without one.

## Cluster Access: MCP-Only

No `kubectl` toolset is given to the agent. Cluster access flows through:

### flux-operator-mcp (primary)
Tools supplied:
- `get_kubernetes_resources` (arbitrary kind/namespace/selector — covers pods,
  nodes, events, PVCs, Deployments, etc.)
- `get_kubernetes_logs`, `get_kubernetes_metrics`
- `get_flux_instance`
- `reconcile_flux_{kustomization,helmrelease,source}`, `resume`/`suspend`
- `search_flux_docs`

**Removed from the Hermes tool whitelist** (`hermes mcp configure`):
`apply_kubernetes_manifest`, `install_flux_instance`, `delete_kubernetes_resource`,
`get/set_kubeconfig_context` (delete *resource* is additionally blocked at RBAC —
see below).

### konflate MCP (context)
GitOps/repo context (the existing `default/konflate` MCP server, in-cluster URL).

### RBAC (scoped to the flux-operator-mcp Deployment's ServiceAccount)
Hard limits, per desired T2 posture:
- `get/list/watch` on workloads, nodes, namespaces, events, PVCs/StorageClasses,
  ConfigMaps, Services, and Flux CRs (Kustomization, HelmRelease, GitRepository,
  OCIRepository, FluxInstance, …).
- **No `get`/`list` on `secrets`** → secret data is unreadable, hard-enforced.
  Secret *references* remain visible in HelmRelease/ExternalSecret manifests.
- `delete` on **pods only**.
- `update`/`patch` on **Flux CRs only** (the annotation-level change that
  `flux reconcile`/`resume`/`suspend` require).
- No `create` on anything → `apply_kubernetes_manifest` fails at RBAC.

The `hermes` agent's own ServiceAccount has **no cluster RBAC**, so a compromised
agent cannot escalate via its own identity.

## Watchdog / Operating Modes

- **Proactive watchdog (primary):** Hermes cron/kanban scheduled checks —
  HelmRelease/GitRepository readiness, pod crash loops, cert expiry, storage
  headroom — pushed via ntfy. Headless cron runs fail-closed
  (`approvals.cron_mode: deny`).
- **Interactive:** built-in dashboard at `hermes.whoverse.dev` (internal only).
- **Autonomous operator (T2-lite):** reconcile stuck Flux, resume suspended,
  delete stuck CrashLoop pods; gated by Hermes hooks/guardrails for the rarer
  destructive moves.
- **Alert-driven: dropped.** No chaski → agent webhook (session spam). Alerts
  keep flowing to ntfy as today; the watchdog investigates on its own schedule.

## Memory (memini → moltbot)

- Install + enable the **memini** plugin (`eleboucher/memini-hermes`);
  `memory.provider: memini`.
- Env: `MEMINI_BASE_URL=http://moltbot-egress.network.svc.cluster.local:8081`,
  `MEMINI_HOME=personal/hermes`, `MEMINI_NAMESPACE=home-ops/hermes`,
  `MEMINI_API_KEY` (if auth required).

## Web / Search Stack

- `web.search_backend: searxng`, `SEARXNG_URL=http://moltbot-egress.network.svc.cluster.local:8080`.
- `web.extract_backend: local-extract` (trafilatura).
- Plugins (`plugins.enabled`):
  ```yaml
  plugins:
    enabled:
      - web                  # searxng + ddgs + brave (does NOT include local-extract)
      - web/local-extract    # trafilatura — must be listed explicitly
  ```
- `security.allow_private_urls: false` — SSRF protection **stays on**; the
  configured SearXNG/local-extract backends are trusted integrations (same as
  moltbot reaching SearXNG on localhost).
- **website_blocklist:** allow `.nexus` (external Cloudflare gateway, behind
  auth); restrict `.dev` (internal/cluster-admin surfaces).

## Model & Secrets

- Provider: **OpenRouter** (static key), model **`deepseek/deepseek-v4-flash-0731`**.
- **ExternalSecret** (1Password Connect, per home-ops convention):
  `OPENROUTER_API_KEY`, ntfy token, Hermes API/dashboard credentials.
- Storage: PVC (`miroir`) for `HERMES_HOME`.

## "Cannot Modify Itself" (security layers)

1. **File Write Safety** — `HERMES_WRITE_SAFE_ROOT=/opt/data:/tmp`; `write_file`/
   `patch` are hard-blocked outside these roots (so `/opt/hermes` code,
   `config.yaml`, `plugins/`, `skills/`, `SOUL.md` are unwritable). Built-in
   denylist protects `auth.json`, `.env`, `mcp-tokens/`, `pairing/`, `~/.ssh/`.
2. **Terminal/shell** — `approvals.deny` glob rules block any command that
   edits protected paths; dangerous-command approval on; hardline blocklist
   (incl. `pkill hermes`/`gateway` self-termination).
3. **RBAC** — no `create`/`update` on its own Deployment, ServiceAccount, or
   Roles/ClusterRoles.
4. **GitOps** — Flux reconciles from git; any patch to its own HelmRelease/
   Kustomization is drift-reverted, so self-tampering cannot persist.
5. **Sandbox** — gVisor (`gvisor` runtime class), `allowPrivilegeEscalation:
   false`, drop ALL capabilities. The container PID 1 is the s6 supervisor (it
   must start as root to seed/chown `/opt/data`, then drops to the `hermes` UID
   10000 for the gateway/dashboard) — so `runAsNonRoot` is not applied to PID
   1; user-namespace + gVisor isolate it. (Verify s6-overlay boot path under the
   `runsc` runtime class during implementation.)
6. **Never YOLO** — no `HERMES_YOLO_MODE`; `approvals.mode` stays
   `smart`/`manual` (never `off`).
7. **No lazy installs** — `security.allow_lazy_installs: false`.
8. **Credential hygiene** — do not add provider keys to `terminal.env_passthrough`
   / `docker_forward_env`; rely on built-in sandbox env filtering.
9. **Prompt-injection scanning** (default on) — keep shipped `SOUL.md`/skills
   benign and declarative.

## Cleanup

- Remove stale `kubernetes/holmes/` (disabled in commit `384374b`).
- Remove/rewire chaski `config.d/10-holmes.yaml` dead flux-alert→holmes target.

## Decided during review (no longer open)

- **Image:** published `nousresearch/hermes-agent` (no local build).
- **konflate MCP:** `http://konflate.default.svc.cluster.local:8080/mcp`
  (streamable HTTP, read-only).
- **gVisor class:** `gvisor`.
- **Model:** `deepseek/deepseek-v4-flash-0731`.
- **memini namespace:** `home-ops/hermes`.
- **Plugins:** one plugin per repo (`hermes plugins install` treats the repo
  root as a single plugin). memini → `eleboucher/memini-hermes`; local-extract
  needs its own source.

## Open Item

- **web/local-extract provenance** — `hermes plugins install <owner/repo>` clones
  a repo whose **root** is the plugin (reads `plugin.yaml`/`__init__.py` at the
  root); a single repo cannot host multiple plugins. local-extract is a
  self-contained plugin dir (`plugin.yaml`/`__init__.py`/`provider.py`).
  Options: (a) publish as its own repo `alinanova21/hermes-local-extract` and
  `hermes plugins install` it; or (b) vendor the plugin files in-repo (home-ops
  ConfigMap) mounted into `/opt/data/plugins/web/local-extract` with no separate
  repo. Choose (a) or (b) during implementation.
