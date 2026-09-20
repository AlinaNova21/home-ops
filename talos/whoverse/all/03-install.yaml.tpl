apiVersion: v1alpha1
kind: UnattendedInstallConfig
provisioning:
  diskSelector:
{{- if hasPrefix "/dev/disk/" .Node.Data.disk }}
    match: '"{{ .Node.Data.disk }}" in disk.symlinks'
{{- else }}
    match: disk.dev_path == "{{ .Node.Data.disk }}"
{{- end }}
