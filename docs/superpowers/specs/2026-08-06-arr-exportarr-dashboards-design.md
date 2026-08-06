# *arr + Sabnzbd Metrics & Dashboards (exportarr)

**Date:** 2026-08-06
**Status:** Approved
**Scope:** `kubernetes/downloads/*` (7 apps) + `kubernetes/monitoring/grafana`

## Problem

The user asked for Grafana dashboards for the *arr stack. Investigation found:

1. **The *arr apps do not expose metrics today.** All 6 *arr apps (sonarr-hd,
   sonarr-anime, radarr-hd, radarr-anime, radarr-uhd, prowlarr) set
   `*__METRICS__ENABLED: "true"` and have ServiceMonitors scraping `/metrics`.
   However, **none of the Servarr apps have native Prometheus support** —
   verified against the Sonarr/Radarr/Prowlarr/Lidarr source trees (zero metric
   or prometheus code). The env var is a no-op: `/metrics` returns the web UI
   HTML (HTTP 200, so targets show `up`, but no series parse). VictoriaMetrics
   contains zero `sonarr_*` / `radarr_*` / `prowlarr_*` series.
2. **sabnzbd has no native metrics** either (SABnzbd 5.x has no Prometheus
   endpoint — verified via source tree scan).
3. **seerr has no metrics source at all**: the `seerr-team/seerr` fork (v3.4.1,
   the image in use) has no metrics route (verified against its route table).
   Upstream Overseerr has native metrics since v1.33, but this deployment is not
   Overseerr, and exportarr does not support seerr. **Seerr is out of scope.**

## Solution

Deploy [exportarr](https://github.com/onedr0p/exportarr) **v2.3.0** (latest
stable) as a sidecar container in each of the 7 apps (6 *arr + sabnzbd).
exportarr is the de-facto standard *arr exporter: it supports sonarr, radarr,
prowlarr, and sabnzbd, and emits rich metrics (library counts, wanted/missing,
queue, download speed, disk space, health checks, indexer stats).

The ServiceMonitors that currently scrape HTML from the app port are re-pointed
at the exportarr port. The no-op `*__METRICS__ENABLED` env vars are removed.

### Per-app change matrix

| App | exportarr URL | API key secret → key |
|---|---|---|
| sonarr-hd | `http://localhost:8989` | `sonarr-hd-config` → `apikey` |
| sonarr-anime | `http://localhost:8989` | `sonarr-anime-config` → `apikey` |
| radarr-hd | `http://localhost:7878` | `radarr-hd-config` → `apikey` |
| radarr-anime | `http://localhost:7878` | `radarr-anime-config` → `apikey` |
| radarr-uhd | `http://localhost:7878` | `radarr-uhd-config` → `apikey` |
| prowlarr | `http://localhost:9696` | `prowlarr-config` → `apikey` |
| sabnzbd | `http://localhost:8080` | `sabnzbd-config` → `apikey` |

All sidecars listen on **`PORT=9707`**. Unique ports are unnecessary in
Kubernetes — each app pod has its own network namespace and exactly one
exportarr sidecar, so there is no collision (exportarr's "unique port" guidance
applies to docker-compose where containers share a host network).

Per helmrelease (`kubernetes/downloads/{app}/app/helmrelease.yaml`):

- Add `exportarr` container to the existing controller:
  - `image: ghcr.io/onedr0p/exportarr` pinned to `v2.3.0` (Renovate-managed)
  - `args: ["sonarr" | "radarr" | "prowlarr" | "sabnzbd"]`
  - `env`: `PORT=9707`, `URL=<app URL>`, `API_KEY` from the app's existing
    `<app>-config` secret (`key: apikey`)
  - container `ports`: `metrics` → containerPort 9707
  - liveness + readiness probes: `httpGet {path: /healthz, port: 9707}`
    (verified `/healthz` exists in exportarr v2.3.0)
  - `resources`: requests 10m/32Mi, limits 128Mi
- Add service port `metrics: {port: 9707}` (routes to the exportarr container)
- ServiceMonitor: point endpoint at `port: metrics`, keep `path: /metrics`,
  `interval: 30s` (repo convention; tunable later), and add a relabel:
  ```yaml
  - targetLabel: instance
    replacement: <app-name>
  ```
  so dashboard instance dropdowns show friendly names instead of `IP:port`.
- Remove `*__METRICS__ENABLED` env vars (no-ops)

### Dashboards

Provisioned via the Grafana Operator pattern already in use
(`kubernetes/monitoring/grafana/app/dashboards/`), datasource VictoriaMetrics,
in a new `GrafanaFolder` **"Media"**:

1. **`media-dashboard`** — exportarr's official multi-app "Media Dashboard"
   (34 panels: Prowlarr indexer stats, Sabnzbd queue/speed, Radarr, Sonarr).
   Vendored inline JSON from the exportarr `v2.3.0` tag
   (`examples/grafana/dashboard2.json`, UID `WURH98Y4k`). It already has
   per-app instance variables (`label_values({__name__=~"sonarr_.*"}, instance)`)
   which the relabel above feeds with friendly names. Imported verbatim — no
   modifications.
2. **`sonarr-v3`** — grafana.com dashboard 21889 "Sonarr v3 + Selector"
   (UID `vGjT_QWMk`), which already has an `Instance` dropdown scoping every
   query by `job`. **One modification**: its variable query references
   `exportarr_app_info` (a v1-era metric that v2.3.0 no longer emits) → replace
   with `label_values({__name__=~"sonarr_.*"}, job)`. The `job` label comes
   free from the ServiceMonitor (defaults to `app.kubernetes.io/name` = service
   name), so the dropdown lists `sonarr-hd` / `sonarr-anime`.
3. **`radarr-v3`** — grafana.com dashboard 12896 "Radarr v3" (UID `F2vfZUNGz`),
   which has **no instance filter** (queries like bare `radarr_movie_total`).
   With 3 Radarr instances, importing verbatim would aggregate all libraries
   together. Modifications:
   - add an `Instance` template variable:
     `label_values({__name__=~"radarr_.*"}, job)` (default: first value)
   - wrap every query with `{job="$Instance"}` (merging where a selector
     already exists)
   - fix the upstream typo `radrr_queue_total` → `radarr_queue_total` (the
     metric name is `radarr_queue_total`; the typo'd panel always renders 0)

All three dashboards are vendored inline via `spec.json` in the
`GrafanaDashboard` CRs (the Media Dashboard and modified per-app dashboards are
not fetchable verbatim from grafana.com), with
`datasources: [{inputName: DS_PROMETHEUS, datasourceName: VictoriaMetrics}]`
following the existing flux-cluster CR pattern.

## Out of scope

- **seerr** — no metrics source exists (seerr-team fork has no metrics endpoint;
  exportarr doesn't support it). Revisit if upstream adds metrics.
- Per-app dashboards beyond Sonarr/Radarr (Prowlarr/Sabnzbd get the Media
  Dashboard section; the per-app ones would need the same JSON surgery).

## Validation

1. Worktree `feat/arr-exportarr-dashboards` based on `main`
2. Baseline `just flate-test` before changes (186 passed)
3. After changes: `pre-commit run --all-files` + `just flate-test`
4. Push feature branch, open PR; do not merge without explicit user order

## Files touched

- `kubernetes/downloads/{sonarr-hd,sonarr-anime,radarr-hd,radarr-anime,radarr-uhd,prowlarr,sabnzbd}/app/helmrelease.yaml` (7)
- `kubernetes/monitoring/grafana/app/folders.yaml` (add a `media` GrafanaFolder CR, title "Media")
- `kubernetes/monitoring/grafana/app/dashboards/{media-dashboard,sonarr-v3,radarr-v3}.yaml` (new)
- `kubernetes/monitoring/grafana/app/kustomization.yaml` (reference new files)
