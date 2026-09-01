apiVersion: v1alpha1
kind: HostnameConfig
auto: "off"
hostname: {{ .Node.Host }}
---
machine:
  files:
    - path: /var/etc/cri/conf.d/20-spegel.part
      op: create
      permissions: 0o000
      content: |
        [plugins."io.containerd.cri.v1.images"]
          discard_unpacked_layers = false
