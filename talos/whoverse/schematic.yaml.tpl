customization:
  systemExtensions:
    officialExtensions:
      - siderolabs/iscsi-tools
      - siderolabs/realtek-firmware
      - siderolabs/gvisor
      {{- if hasKey .Node.Data "vm" }}
      - siderolabs/qemu-guest-agent
      {{- end }}
      - siderolabs/amdgpu
      - siderolabs/i915
      - siderolabs/xe
      - siderolabs/drbd
