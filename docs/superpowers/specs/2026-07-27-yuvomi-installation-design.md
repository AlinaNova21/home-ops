# Yuvomi Installation Design

## Overview

Family planner app (self-hosted) running as a single Docker container. Installing to Kubernetes via Flux CD GitOps using bjw-s app-template chart, with kopiur backup component, external secrets via 1Password Connect.

## Structure

```
kubernetes/default/yuvomi/
├── ks.yaml
└── app/
    ├── kustomization.yaml
    ├── helmrelease.yaml
    ├── externalsecret.yaml
    └── httproute.yaml
```

## Files

### ks.yaml
- Flux Kustomization, targetNamespace: default
- Components: `../../../components/kopiur/backup`
- APP variable for backup component substitution

### helmrelease.yaml
- Chart: bjw-s app-template 5.0.1
- Image: ghcr.io/ulsklyc/yuvomi:latest (port 3000)
- Env: TZ, TRUST_PROXY, DOCUMENT_STORAGE_LOCAL_ENABLED, SESSION_SECRET, DB_ENCRYPTION_KEY
- Persistence: PVC at /data (1Gi, ceph-rbd, Restore dataSourceRef)

### externalsecret.yaml
- SESSION_SECRET: external-secrets password generator (24 bytes, base64)
- DB_ENCRYPTION_KEY: from 1Password item `yuvomi-secrets` field `dbEncryptionKey`
- Secret name: yuvomi-secrets

### httproute.yaml
- Gateway: external in network namespace
- Hostname: family.whoverse.nexus
- Path: / → port 3000

## 1Password Item
- Item: yuvomi-secrets
- Field: dbEncryptionKey (user-generated)

## Integration
- Namespace: default (already exists)
- Backup: kopiur/backup component (same as barcodebuddy, grocy, speedtest-tracker)
- Ingress: external gateway (Cloudflare Tunnel)
