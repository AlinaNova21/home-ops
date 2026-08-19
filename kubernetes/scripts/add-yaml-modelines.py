#!/usr/bin/env python3
"""Add ``# yaml-language-server: $schema=<url>`` modelines to Kubernetes manifests.

Walks the kubernetes/ tree, parses each YAML file, and for every document with a
known (apiVersion, kind) emits a modeline after the leading ``---`` marker. For
files that lack a leading ``---``, inserts both the marker and the modeline.

The convention matches `onedr0p/home-ops`: each doc gets its own ``---\n# yaml-
language-server: $schema=<url>`` pair, so multi-doc files (e.g. ``ks.yaml`` with
a dependsOn block as a second doc) get one modeline per doc.

Idempotent: skips files where every document already carries the expected
modeline. Skips SOPS-encrypted files (``apiVersion: ENC[...]``) and files under
``kubernetes/bootstrap/`` and ``kubernetes/flux-system/flux-config/app/``.

Schemas come from https://k8s-schemas.home-operations.com for CRDs and from
https://json.schemastore.org/kustomization for plain kustomize manifests. Add
new CRDs to ``SCHEMA_MAP`` as they land.
"""
from __future__ import annotations

import argparse
import sys
from collections import Counter
from pathlib import Path
from typing import Iterable

import yaml

SCHEMA_BASE = "https://k8s-schemas.home-operations.com"
SCHEMASTORE_KUSTOMIZE = "https://json.schemastore.org/kustomization"

SCHEMA_MAP: dict[tuple[str, str], str] = {
    # Flux Kustomize Toolkit
    ("kustomize.toolkit.fluxcd.io/v1", "Kustomization"):
        f"{SCHEMA_BASE}/kustomize.toolkit.fluxcd.io/kustomization_v1.json",

    # Flux Helm Toolkit
    ("helm.toolkit.fluxcd.io/v2", "HelmRelease"):
        f"{SCHEMA_BASE}/helm.toolkit.fluxcd.io/helmrelease_v2.json",

    # Flux Source Toolkit
    ("source.toolkit.fluxcd.io/v1", "OCIRepository"):
        f"{SCHEMA_BASE}/source.toolkit.fluxcd.io/ocirepository_v1.json",
    ("source.toolkit.fluxcd.io/v1", "HelmRepository"):
        f"{SCHEMA_BASE}/source.toolkit.fluxcd.io/helmrepository_v1.json",
    ("source.toolkit.fluxcd.io/v1", "Bucket"):
        f"{SCHEMA_BASE}/source.toolkit.fluxcd.io/bucket_v1.json",
    ("source.toolkit.fluxcd.io/v1", "GitRepository"):
        f"{SCHEMA_BASE}/source.toolkit.fluxcd.io/gitrepository_v1.json",
    ("source.toolkit.fluxcd.io/v1", "HelmChart"):
        f"{SCHEMA_BASE}/source.toolkit.fluxcd.io/helmchart_v1.json",
    ("source.toolkit.fluxcd.io/v1", "ExternalArtifact"):
        f"{SCHEMA_BASE}/source.toolkit.fluxcd.io/externalartifact_v1.json",

    # Flux Image Toolkit
    ("image.toolkit.fluxcd.io/v1", "ImagePolicy"):
        f"{SCHEMA_BASE}/image.toolkit.fluxcd.io/imagepolicy_v1.json",
    ("image.toolkit.fluxcd.io/v1", "ImageRepository"):
        f"{SCHEMA_BASE}/image.toolkit.fluxcd.io/imagerepository_v1.json",
    ("image.toolkit.fluxcd.io/v1", "ImageUpdateAutomation"):
        f"{SCHEMA_BASE}/image.toolkit.fluxcd.io/imageupdateautomation_v1.json",

    # Flux Notification Toolkit
    ("notification.toolkit.fluxcd.io/v1", "Receiver"):
        f"{SCHEMA_BASE}/notification.toolkit.fluxcd.io/receiver_v1.json",
    ("notification.toolkit.fluxcd.io/v1beta3", "Alert"):
        f"{SCHEMA_BASE}/notification.toolkit.fluxcd.io/alert_v1beta3.json",
    ("notification.toolkit.fluxcd.io/v1beta3", "Provider"):
        f"{SCHEMA_BASE}/notification.toolkit.fluxcd.io/provider_v1beta3.json",

    # Flux Operator
    ("fluxcd.controlplane.io/v1", "FluxInstance"):
        f"{SCHEMA_BASE}/fluxcd.controlplane.io/fluxinstance_v1.json",

    # Gateway API (core)
    ("gateway.networking.k8s.io/v1", "HTTPRoute"):
        f"{SCHEMA_BASE}/gateway.networking.k8s.io/httproute_v1.json",
    ("gateway.networking.k8s.io/v1", "Gateway"):
        f"{SCHEMA_BASE}/gateway.networking.k8s.io/gateway_v1.json",
    ("gateway.networking.k8s.io/v1", "GatewayClass"):
        f"{SCHEMA_BASE}/gateway.networking.k8s.io/gatewayclass_v1.json",
    ("gateway.networking.k8s.io/v1", "BackendTLSPolicy"):
        f"{SCHEMA_BASE}/gateway.networking.k8s.io/backendtlspolicy_v1.json",

    # Envoy Gateway (Gateway API extension)
    ("gateway.envoyproxy.io/v1alpha1", "EnvoyProxy"):
        f"{SCHEMA_BASE}/gateway.envoyproxy.io/envoyproxy_v1alpha1.json",
    ("gateway.envoyproxy.io/v1alpha1", "SecurityPolicy"):
        f"{SCHEMA_BASE}/gateway.envoyproxy.io/securitypolicy_v1alpha1.json",
    ("gateway.envoyproxy.io/v1alpha1", "ClientTrafficPolicy"):
        f"{SCHEMA_BASE}/gateway.envoyproxy.io/clienttrafficpolicy_v1alpha1.json",
    ("gateway.envoyproxy.io/v1alpha1", "BackendTrafficPolicy"):
        f"{SCHEMA_BASE}/gateway.envoyproxy.io/backendtrafficpolicy_v1alpha1.json",

    # External Secrets
    ("external-secrets.io/v1", "ExternalSecret"):
        f"{SCHEMA_BASE}/external-secrets.io/externalsecret_v1.json",
    ("external-secrets.io/v1", "SecretStore"):
        f"{SCHEMA_BASE}/external-secrets.io/secretstore_v1.json",
    ("external-secrets.io/v1", "ClusterSecretStore"):
        f"{SCHEMA_BASE}/external-secrets.io/clustersecretstore_v1.json",
    ("external-secrets.io/v1alpha1", "PushSecret"):
        f"{SCHEMA_BASE}/external-secrets.io/pushsecret_v1alpha1.json",

    # cert-manager
    ("cert-manager.io/v1", "Certificate"):
        f"{SCHEMA_BASE}/cert-manager.io/certificate_v1.json",
    ("cert-manager.io/v1", "Issuer"):
        f"{SCHEMA_BASE}/cert-manager.io/issuer_v1.json",
    ("cert-manager.io/v1", "ClusterIssuer"):
        f"{SCHEMA_BASE}/cert-manager.io/clusterissuer_v1.json",

    # Cilium
    ("cilium.io/v2", "CiliumNetworkPolicy"):
        f"{SCHEMA_BASE}/cilium.io/ciliumnetworkpolicy_v2.json",
    ("cilium.io/v2", "CiliumClusterwideNetworkPolicy"):
        f"{SCHEMA_BASE}/cilium.io/ciliumclusterwidenetworkpolicy_v2.json",
    ("cilium.io/v2", "CiliumBGPClusterConfig"):
        f"{SCHEMA_BASE}/cilium.io/ciliumbgpclusterconfig_v2.json",
    ("cilium.io/v2", "CiliumLoadBalancerIPPool"):
        f"{SCHEMA_BASE}/cilium.io/ciliumloadbalancerippool_v2.json",
    ("cilium.io/v2alpha1", "CiliumBGPAdvertisement"):
        f"{SCHEMA_BASE}/cilium.io/ciliumbgpadvertisement_v2alpha1.json",
    ("cilium.io/v2alpha1", "CiliumBGPPeerConfig"):
        f"{SCHEMA_BASE}/cilium.io/ciliumbgppeerconfig_v2alpha1.json",

    # Prometheus Operator
    ("monitoring.coreos.com/v1", "ServiceMonitor"):
        f"{SCHEMA_BASE}/monitoring.coreos.com/servicemonitor_v1.json",
    ("monitoring.coreos.com/v1", "PrometheusRule"):
        f"{SCHEMA_BASE}/monitoring.coreos.com/prometheusrule_v1.json",
    ("monitoring.coreos.com/v1", "PodMonitor"):
        f"{SCHEMA_BASE}/monitoring.coreos.com/podmonitor_v1.json",
    ("monitoring.coreos.com/v1", "Probe"):
        f"{SCHEMA_BASE}/monitoring.coreos.com/probe_v1.json",

    # VictoriaMetrics Operator
    ("operator.victoriametrics.com/v1beta1", "VMServiceScrape"):
        f"{SCHEMA_BASE}/operator.victoriametrics.com/vmservicescrape_v1beta1.json",
    ("operator.victoriametrics.com/v1beta1", "VMPodScrape"):
        f"{SCHEMA_BASE}/operator.victoriametrics.com/vmpodscrape_v1beta1.json",
    ("operator.victoriametrics.com/v1beta1", "PrometheusRule"):
        f"{SCHEMA_BASE}/operator.victoriametrics.com/vmrule_v1beta1.json",
    ("operator.victoriametrics.com/v1beta1", "VMAlert"):
        f"{SCHEMA_BASE}/operator.victoriametrics.com/vmalert_v1beta1.json",
    ("operator.victoriametrics.com/v1", "VLCluster"):
        f"{SCHEMA_BASE}/operator.victoriametrics.com/vlcluster_v1.json",

    # Volume Snapshots
    ("snapshot.storage.k8s.io/v1", "VolumeSnapshot"):
        f"{SCHEMA_BASE}/snapshot.storage.k8s.io/volumesnapshot_v1.json",
    ("snapshot.storage.k8s.io/v1", "VolumeSnapshotClass"):
        f"{SCHEMA_BASE}/snapshot.storage.k8s.io/volumesnapshotclass_v1.json",
    ("snapshot.storage.k8s.io/v1", "VolumeSnapshotContent"):
        f"{SCHEMA_BASE}/snapshot.storage.k8s.io/volumesnapshotcontent_v1.json",

    # Kyverno
    ("kyverno.io/v1", "Policy"):
        f"{SCHEMA_BASE}/kyverno.io/policy_v1.json",
    ("kyverno.io/v1", "ClusterPolicy"):
        f"{SCHEMA_BASE}/kyverno.io/clusterpolicy_v1.json",

    # 1Password Connect
    ("onepassword.com/v1", "OnePasswordItem"):
        f"{SCHEMA_BASE}/onepassword.com/onepassworditem_v1.json",

    # Kopiur
    ("kopiur.home-operations.com/v1alpha1", "ClusterRepository"):
        f"{SCHEMA_BASE}/kopiur.home-operations.com/clusterrepository_v1alpha1.json",
    ("kopiur.home-operations.com/v1alpha1", "Repository"):
        f"{SCHEMA_BASE}/kopiur.home-operations.com/repository_v1alpha1.json",
    ("kopiur.home-operations.com/v1alpha1", "Restore"):
        f"{SCHEMA_BASE}/kopiur.home-operations.com/restore_v1alpha1.json",
    ("kopiur.home-operations.com/v1alpha1", "Snapshot"):
        f"{SCHEMA_BASE}/kopiur.home-operations.com/snapshot_v1alpha1.json",
    ("kopiur.home-operations.com/v1alpha1", "SnapshotPolicy"):
        f"{SCHEMA_BASE}/kopiur.home-operations.com/snapshotpolicy_v1alpha1.json",
    ("kopiur.home-operations.com/v1alpha1", "SnapshotSchedule"):
        f"{SCHEMA_BASE}/kopiur.home-operations.com/snapshotschedule_v1alpha1.json",

    # Miroir
    ("miroir.home-operations.com/v1alpha1", "MiroirNode"):
        f"{SCHEMA_BASE}/miroir.home-operations.com/miroirnode_v1alpha1.json",
    ("miroir.home-operations.com/v1alpha1", "MiroirNodeGroup"):
        f"{SCHEMA_BASE}/miroir.home-operations.com/miroirnodegroup_v1alpha1.json",

    # Tailscale Operator
    ("tailscale.com/v1alpha1", "Connector"):
        f"{SCHEMA_BASE}/tailscale.com/connector_v1alpha1.json",
    ("tailscale.com/v1alpha1", "ProxyClass"):
        f"{SCHEMA_BASE}/tailscale.com/proxyclass_v1alpha1.json",
    ("tailscale.com/v1alpha1", "ProxyGroup"):
        f"{SCHEMA_BASE}/tailscale.com/proxygroup_v1alpha1.json",
}

KUSTOMIZE_KINDS: set[tuple[str, str]] = {
    ("kustomize.config.k8s.io/v1beta1", "Kustomization"),
    ("kustomize.config.k8s.io/v1alpha1", "Component"),
}


def find_schema(api_version: str | None, kind: str | None) -> str | None:
    if not api_version or not kind:
        return None
    if (api_version, kind) in KUSTOMIZE_KINDS:
        return SCHEMASTORE_KUSTOMIZE
    return SCHEMA_MAP.get((api_version, kind))


def is_sops_encrypted(text: str) -> bool:
    return "ENC[AES256_GCM" in text[:1024]


def parse_docs(text: str) -> list[dict | None]:
    """Return the list of YAML documents (dicts) in the file. None for empty docs."""
    docs: list[dict | None] = []
    try:
        for doc in yaml.safe_load_all(text):
            docs.append(doc if isinstance(doc, dict) else None)
    except yaml.YAMLError:
        return []
    return docs


def doc_schemas(docs: list[dict | None]) -> list[str | None]:
    return [find_schema(d.get("apiVersion"), d.get("kind")) if d else None for d in docs]


def has_existing_modeline(line: str) -> bool:
    return line.lstrip().startswith("# yaml-language-server:")


def transform(text: str) -> tuple[str, str]:
    """Return (new_text, status).

    status is one of:
      'no-change' — nothing to do
      'updated'   — at least one modeline was added or replaced
    """
    docs = parse_docs(text)
    if not docs:
        return text, "no-change"

    schemas = doc_schemas(docs)
    if not any(schemas):
        return text, "no-change"

    lines = text.splitlines(keepends=True)
    if not lines:
        return text, "no-change"

    sep_positions = [i for i, line in enumerate(lines) if line.rstrip() == "---"]
    if sep_positions and sep_positions[0] == 0:
        doc_starts: list[int] = list(sep_positions)
    else:
        doc_starts = [0, *sep_positions]

    insertions: list[tuple[int, str, str]] = []

    for doc_idx, start_line in enumerate(doc_starts):
        if doc_idx >= len(schemas):
            break
        schema = schemas[doc_idx]
        if not schema:
            continue
        modeline = f"# yaml-language-server: $schema={schema}\n"

        if start_line == 0 and (not lines or lines[0].rstrip() != "---"):
            if lines and has_existing_modeline(lines[0]):
                insertions.append((0, "---\n" + modeline, "replace"))
            else:
                insertions.append((0, "---\n" + modeline, "insert"))
            continue

        after = start_line + 1
        while after < len(lines) and lines[after].strip() == "":
            after += 1
        if after < len(lines) and has_existing_modeline(lines[after]):
            continue
        insertions.append((after, modeline, "insert"))

    if not insertions:
        return text, "no-change"

    insertions.sort(key=lambda x: x[0], reverse=True)
    for line_idx, payload, mode in insertions:
        if mode == "replace":
            lines[line_idx] = payload
        else:
            lines.insert(line_idx, payload)

    return "".join(lines), "updated"


def iter_yamls(root: Path) -> Iterable[Path]:
    skip_dirs = {"bootstrap", "sops"}
    for pattern in ("*.yaml", "*.yml"):
        for path in sorted(root.rglob(pattern)):
            rel = path.relative_to(root)
            if any(part in skip_dirs for part in rel.parts):
                continue
            yield path


def main() -> int:
    doc = __doc__ or ""
    parser = argparse.ArgumentParser(description=doc.splitlines()[0])
    parser.add_argument("--root", type=Path, default=Path("kubernetes"),
                        help="Root directory to scan (default: kubernetes)")
    parser.add_argument("--dry-run", action="store_true",
                        help="Print planned changes without writing")
    parser.add_argument("--quiet", action="store_true",
                        help="Only print the summary")
    args = parser.parse_args()

    if not args.root.is_dir():
        print(f"error: {args.root} is not a directory", file=sys.stderr)
        return 1

    counts: Counter[str] = Counter()
    for path in iter_yamls(args.root):
        try:
            text = path.read_text()
        except (OSError, UnicodeDecodeError) as e:
            counts[f"read-error ({e})"] += 1
            continue

        if is_sops_encrypted(text):
            counts["skip-sops"] += 1
            continue

        new_text, status = transform(text)
        counts[status] += 1
        if status == "updated":
            if not args.dry_run:
                path.write_text(new_text)
            if not args.quiet:
                action = "updated" if not args.dry_run else "would-update"
                print(f"{action} {path}")

    print()
    print("Summary:")
    for status, n in sorted(counts.items()):
        print(f"  {n:>4} {status}")
    return 0


if __name__ == "__main__":
    sys.exit(main())