# *arr Data Loss — Postmortem (prowlarr, sonarr-hd, radarr-uhd)

**Date:** 2026-07-28 to 2026-08-06
**Duration:** ~9 days (detection lag)
**Severity:** P2 — Three download-arr apps lost library/indexer data; recovered from backups
**Status:** All three restored and verified; offsite mirror and alerting still open

> Backups never stopped — they faithfully captured each wipe. Detection relied on manual
> inspection; the B2 offsite mirror was stale and initially masked the true state. Recovery
> via one-off Kopiur `Restore` CRs (`pvcRef`, point-in-time snapshot pinning) succeeded for
> all three affected apps.

---

## Summary

Three *arr applications in `downloads` lost their data over a five-day window (Jul 31 –
Aug 4): **sonarr-hd** (141 series), **radarr-uhd** (966 movies), and **prowlarr** (5 indexers,
8 app connections). The data-loss events were staggered per app — consistent with individual
app reinstalls/recreations, not a single cluster event. The Kopiur backup system kept running
throughout and captured each collapse as a ~90–99% snapshot size drop, but nothing alerted on
the delta. The offsite B2 mirror stopped receiving content around Jul 29, so the local kopia
CLI (connected to B2 by default) made it look like "backups stopped on 07-28" — the live data
was in the Garage repo all along.

All three apps were restored from their last correct Garage snapshots using one-off Kopiur
`Restore` CRs that wrote into the existing PVCs (no PVC deletion), with point-in-time snapshot
pinning and per-app mover UIDs. Data loss window: prowlarr ~2 days, radarr-uhd ~4 days,
sonarr-hd ~6 days.

---

## Timeline (CDT)

| When | Event |
|---|---|
| ~07-28 | All *arr PVCs recreated (9d old on 08-06); snapshot schedules for the apps keep running |
| ~07-29 | B2 offsite mirror stops receiving content (`kopiur-mirror` cronjob schedules runs but no jobs/output reach B2) |
| 07-30 04:24 | **Last good sonarr-hd snapshot** (793 MB) |
| 07-31 19:45 | sonarr-hd app restart → data wiped (Sentry/asp dirs recreated) |
| 08-01 18:15 | First collapsed sonarr-hd snapshot (4.6 MB vs 793 MB) |
| 08-01 18:51 | **Last good radarr-uhd snapshot** (1.6 GB) |
| 08-02 08:54 | radarr-uhd app restart → data wiped |
| 08-02 18:51 | First collapsed radarr-uhd snapshot (3.7 MB vs 1.6 GB) |
| 08-03 18:02 | **Last good prowlarr snapshot** (73.7 MB) |
| 08-04 15:33 | prowlarr app restart → data wiped |
| 08-04 18:02 | First collapsed prowlarr snapshot (4.1 MB vs 73.7 MB) |
| 08-06 01:27 | Incident detected; investigation begins (B2 shows stale data, garage repo shows collapse) |
| 08-06 ~02:00 | All three restored via one-off Kopiur restores; DBs verified |

---

## Root causes

1. **Data-loss trigger (unconfirmed).** Staggered per-app restarts (07-31, 08-02, 08-04) with
   PVC recreation ~07-28 as the common ancestor. HelmRelease/deployment history around those
   dates has not yet been reviewed to pin the exact trigger (app reinstall vs storage migration
   vs chart change).
2. **No alerting on snapshot size collapse.** The backup system detected the collapse (90–99%
   size drop) but kept backing up the empty state silently. No threshold alerting on per-source
   snapshot size deltas, failed snapshot jobs, or `errors:` counts.
3. **Stale B2 mirror masked the real state.** The offsite mirror stopped syncing ~07-29
   (scheduled but no jobs/content). The default local kopia connection points at B2, which made
   the initial investigation conclude "backups stopped 07-28" instead of "data collapsed 08-04".
4. **WAL capture gap (minor).** Some snapshots report `errors:1` where the SQLite `-wal` failed
   to be captured (e.g. radarr-anime). The main DB alone can understate contents; the three
   affected apps' last-good snapshots happened to include the WAL.

---

## Impact

| App | Lost | Restored from | Verified post-restore |
|---|---|---|---|
| prowlarr | 5 indexers, 8 app connections, 1 download client | 08-03 18:02 (73.7 MB) | 5 indexers, 8 applications, 1 download client |
| sonarr-hd | 141 series | 07-30 04:24 (793 MB) | 141 series (sonarr.db 397 MB) |
| radarr-uhd | 966 movies | 08-01 18:51 (1.6 GB) | 966 movies, 1 import list |

- **radarr-anime / sonarr-anime:** 0 movies/series in *all* snapshots and app self-backups
  going back to Jul 7–14 — either always empty or lost before the backup window. **Not
  recoverable from backups.** Separate investigation required.
- Anything changed between the last good snapshot and the wipe is unrecoverable.

---

## Recovery

- Connected kopia CLI to the **Garage repo** (live, `192.168.2.193:30188`, bucket
  `k8s-cluster-backup`) with the in-cluster `kopiur-repository-secret` — B2 was the red herring.
- Located last correct snapshots via snapshot size history per source.
- One-off Kopiur `Restore` CRs (`<app>-restore-manual`), following the existing
  `zot-restore-manual` precedent:
  - `source.fromPolicy.asOf` (RFC3339, UTC) to pin the last correct snapshot —
    `offset: 0` would have restored the *collapsed* snapshot.
  - `target.pvcRef` → write into the existing PVC (no PVC deletion).
  - `mover.securityContext` UID matched per app (prowlarr 65534, sonarr-hd/radarr-uhd 1000).
- Flow per app: scale deployment to 0 → apply Restore → wait `phase: Completed` → verify
  resolved snapshot ID + DB sizes → scale back to 1.
- Post-restore functional checks: prowlarr (sqlite count), sonarr-hd (app scanning series),
  radarr-uhd (sqlite count 966 movies).
- Blip: sonarr-hd and radarr-uhd each had one container restart on first boot after scale-up
  (restored `-wal`/`-shm` pairing triggers SQLite recovery), then came up clean.

---

## Action items

1. **Fix the B2 mirror.** `kopiur-mirror` schedules but produces no jobs/content since ~07-29 —
   Garage is currently the only copy of the repo. Investigate CronJob/controller behavior.
2. **Alert on snapshot size deltas.** Per-source threshold (e.g. >50% drop between consecutive
   snapshots); alert on failed snapshot jobs and snapshot `errors:` counts.
3. **Determine the wipe trigger.** Review HelmRelease/deployment history for prowlarr,
   sonarr-hd, radarr-uhd around 07-28 → 08-04.
4. **Investigate radarr-anime/sonarr-anime.** Confirm whether empty libraries are expected
   (empty in every snapshot and self-backup back to Jul 7–14).
5. **Housekeeping.** Delete the three `*-restore-manual` Restore CRs; address kopia
   "too many index blobs (1201)" maintenance warning.
6. **Restore drills.** This was effectively the first real restore — it worked, but restore is
   currently a manual, unscripted path. Consider documenting/drilling it.
