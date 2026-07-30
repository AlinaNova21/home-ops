# Stage backup ResourceGraphDefinition for kro

- **Date:** 2026-07-27
- **Status:** Done — RGD live on cluster, end-to-end test passed. Migration of existing apps is intentionally deferred.
- **Owner:** home-ops maintainers

## 1. Problem

The backup pipeline for the 13+ apps in this repo uses a kustomize component (`kubernetes/components/kopiur/backup/`) that ships three templates — SnapshotPolicy, SnapshotSchedule, Restore — and is parameterised by `APP` postBuild substitution. The same pattern applies to the multi-PVC seafile app via `kubernetes/components/kopiur/seafile-backup/`.

This works, but:

- Per-app backup setup is verbose (kustomize + postBuild + 3 rendered files), and the only valid `APP` is documented by convention.
- Schema validation is absent — wrong substitution silently breaks the SnapshotPolicy name.
- Defaults are hardcoded in the template; per-app retention overrides would require forking the component.
- Status observability requires joining `kubectl get snapshotpolicy` and `kubectl get restore` per app.
- Multi-PVC support (seafile) lives in a separate component rather than a parameter on the main one.

kro (ResourceGraphDefinitions) replaces this with a typed `Backup` API: per-app instances are validated at admission, status is centralised, and defaults are declared once.

## 2. Approach

Add one ResourceGraphDefinition — `backup` — at `kubernetes/kro-system/kro/app/backup-rgd.yaml`. Migrate zero existing apps in this PR; just stage the RGD so it's available the day an app author wants to adopt it.

The RGD renders three resources per `Backup` instance:

- `SnapshotPolicy` (named after the instance, sources = `pvcNames` mapped)
- `SnapshotSchedule` (named after the instance, hourly cron by default)
- `Restore` (one per PVC via `forEach`, named after the PVC so the existing `dataSourceRef.name: ${APP}` convention resolves)

## 3. Target layout

```
kubernetes/
└── kro-system/
    └── kro/
        └── app/
            ├── helmrelease.yaml          (existing)
            ├── kustomization.yaml        (EDIT — add kro-rbac.yaml, backup-rgd.yaml)
            ├── kro-rbac.yaml             (NEW — aggregated ClusterRole for backup RGD)
            └── backup-rgd.yaml           (NEW — the RGD itself)
```

## 4. The RGD

`kubernetes/kro-system/kro/app/backup-rgd.yaml`:

```yaml
---
apiVersion: kro.run/v1alpha1
kind: ResourceGraphDefinition
metadata:
  name: backup
spec:
  schema:
    apiVersion: v1alpha1
    kind: Backup
    spec:
      pvcNames: "[]string | required=true minItems=1 maxItems=20"
      repository: string | default="whoverse"
      credentialProjection: boolean | default=true
      schedule: string | default="H * * * *"
      retention:
        keepDaily: integer | default=7
        keepWeekly: integer | default=4
        keepMonthly: integer | default=3
    status:
      ready: ${policy.status.conditions.exists(c, c.type == 'Ready' && c.status == 'True')}
      activeSnapshotCount: ${policy.status.retention.activeSnapshotCount}
      lastSnapshotTime: ${string(policy.status.lastSuccessfulSnapshot)}
      restoreReady: ${restore.all(r, r.status.phase == 'Completed')}

  resources:
    - id: policy
      template:
        apiVersion: kopiur.home-operations.com/v1alpha1
        kind: SnapshotPolicy
        metadata:
          name: ${schema.metadata.name}
        spec:
          repository:
            kind: ClusterRepository
            name: ${schema.spec.repository}
          credentialProjection:
            enabled: ${schema.spec.credentialProjection}
          sources: '${schema.spec.pvcNames.map(n, {"pvc": {"name": n}, "sourcePathStrategy": "PvcName"})}'
          retention:
            keepDaily: ${schema.spec.retention.keepDaily}
            keepWeekly: ${schema.spec.retention.keepWeekly}
            keepMonthly: ${schema.spec.retention.keepMonthly}

    - id: schedule
      template:
        apiVersion: kopiur.home-operations.com/v1alpha1
        kind: SnapshotSchedule
        metadata:
          name: ${schema.metadata.name}
        spec:
          policyRef:
            name: ${schema.metadata.name}
          schedule:
            cron: ${schema.spec.schedule}

    - id: restore
      forEach:
        - pvc: ${schema.spec.pvcNames}
      template:
        apiVersion: kopiur.home-operations.com/v1alpha1
        kind: Restore
        metadata:
          name: ${pvc}
        spec:
          source:
            fromPolicy:
              name: ${schema.metadata.name}
              offset: 0
          policy:
            onMissingSnapshot: Continue
          target:
            populator: {}
          credentialProjection:
            enabled: ${schema.spec.credentialProjection}
```

## 5. RBAC

kro chart with `rbac.mode: aggregation` provisions only the static defaults — full access to `ResourceGraphDefinition`, `GraphRevision`, `CustomResourceDefinition`, plus leases/configmaps/events. Generated CRDs (`backups.kro.run`) and the kopiur resources the RGD reconciles (`snapshotpolicies`, `snapshotschedules`, `restores`) are NOT included.

`kubernetes/kro-system/kro/app/kro-rbac.yaml` adds the missing aggregation:

```yaml
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: kro:controller:backup
  labels:
    rbac.kro.run/aggregate-to-controller: "true"
rules:
  - apiGroups: ["kro.run"]
    resources: ["backups"]
    verbs: ["*"]
  - apiGroups: ["kopiur.home-operations.com"]
    resources: ["snapshotpolicies", "snapshotschedules", "restores"]
    verbs: ["*"]
```

Without this, kro's dynamic controller logs:

```
Watch error: failed to list *v1.PartialObjectMetadata: backups.kro.run is forbidden:
User "system:serviceaccount:kro-system:kro" cannot list resource "backups"
in API group "kro.run" at the cluster scope
```

…and `ControllerReady` stays `FailedToStart` with `cache sync timeout` forever.

## 6. Naming convention

| Concept | Single-PVC app | Multi-PVC app (seafile) |
|---|---|---|
| `Backup` instance `metadata.name` (= `metadata.name: ${APP}`) | `prowlarr` | `seafile` |
| `SnapshotPolicy` resource name | `prowlarr` | `seafile` (one policy, multiple sources) |
| `SnapshotSchedule` resource name | `prowlarr` | `seafile` |
| `Restore` resource name(s) | `prowlarr` | `seafile-shared`, `seafile-mariadb-data`, `seafile-redis-data` |
| App PVC `dataSourceRef.name` | `${APP}` → `prowlarr` | per-PVC: `seafile-shared`, etc. |

For the 12 single-PVC apps, `${APP}` substitution keeps the existing app-side convention unchanged. Seafile is the only case where per-PVC naming forces a one-time helmrelease values edit.

## 7. Example instances (for future adoption, NOT applied in this PR)

Single PVC:

```yaml
---
apiVersion: kro.run/v1alpha1
kind: Backup
metadata:
  name: ${APP}
spec:
  pvcNames:
    - ${APP}
```

Multi PVC:

```yaml
---
apiVersion: kro.run/v1alpha1
kind: Backup
metadata:
  name: ${APP}
spec:
  pvcNames:
    - ${APP}-shared
    - ${APP}-mariadb-data
    - ${APP}-redis-data
```

## 8. Gotchas hit during staging

These are recorded so the next RGD author doesn't trip them:

1. **`forEach` syntax is `forEach: [{var: expr}]`, not `forEach: expr + var: name`.** A bare expression with a separate `var` field is rejected: `.spec.resources[2].var: field not declared in schema`.

2. **CEL `map()` returning maps of maps confuses kro's static type checker** when the target CRD uses `oneOf`/`x-kubernetes-validations` for union types. The `SnapshotPolicy.spec.sources` is a list of objects where exactly one of `pvc`/`pvcSelector`/`nfs` must be set, plus optional `sourcePathStrategy`/`sourcePathOverride`. kro doesn't model the union; it sees a flat object schema. Workaround: include `sourcePathStrategy: "PvcName"` in the CEL map so the rendered object matches the static shape byte-for-byte.

3. **Status fields require CEL expressions, not bare type declarations.** `ready: boolean` is rejected with `status fields without expressions are not supported`. Each status field must reference a managed resource via CEL.

4. **kro's chart-level RBAC doesn't grant access to generated CRDs** under `rbac.mode: aggregation`. Per https://kro.run/docs/advanced/access-control, you must add `ClusterRole`s with label `rbac.kro.run/aggregate-to-controller: "true"` for every resource type the RGD manages.

5. **kro's in-cluster watch needs a pod restart after RBAC is granted**, even if the ServiceAccount now has permission. The dynamic-controller's RBAC cache only refreshes on pod restart (verified by `kubectl auth can-i` returning `yes` before the restart but `cache sync timeout` persisting). When staging an RBAC fix without a pod restart, the controller will continue to log RBAC denials until the next pod restart.

## 9. Validation

Performed:

```bash
# File-level
kustomize build kubernetes/kro-system/kro/app  # renders 3 resources (HR, RBAC, RGD)
kustomize build kubernetes/ | kubeconform -strict -ignore-missing-schemas -schema-location default -schema-location '...'  # exit 0
pre-commit run --all-files  # passed

# Cluster-level
kubectl get resourcegraphdefinition backup -o yaml  # state: Active, all conditions True
kubectl auth can-i list backups.kro.run --as=system:serviceaccount:kro-system:kro  # yes

# End-to-end smoke test (committed to git as a runbook, not as a resource)
kubectl apply -f - <<EOF
apiVersion: kro.run/v1alpha1
kind: Backup
metadata: { name: rgd-smoke-test, namespace: default }
spec: { pvcNames: [rgd-smoke-test-pvc] }
EOF
# Expected: SnapshotPolicy/rgd-smoke-test, SnapshotSchedule/rgd-smoke-test,
# Restore/rgd-smoke-test-pvc created with correct references.
# Deleting the Backup cleans up all three.
```

Smoke test passed. After cleanup, the three rendered resources are gone.

## 10. Rollback

```bash
kubectl delete resourcegraphdefinition backup
kubectl delete clusterrole kro:controller:backup
git revert <commit-sha>           # removes backup-rgd.yaml + kro-rbac.yaml + kustomization.yaml edits
```

No state outside `kro-system` is touched. No `Backup` instances exist (migration is OOS for this PR), so no cascading deletions.

## 11. Out of scope (deliberately deferred)

- Migrating any of the 13 existing apps from `components/kopiur/backup` to the kro RGD. Future work.
- Deleting `kubernetes/components/kopiur/backup/` or `kubernetes/components/kopiur/seafile-backup/`. Once all apps migrate, these can be deleted in a separate PR.
- Migrating `kubernetes/components/kopiur/vmstorage-backup/` (3 shards) and `vlstorage-*` (2 shards). Same shape, same migration pattern, separate task.
- Wiring the Backup RGD status into the existing `monitoring/` observability stack.
