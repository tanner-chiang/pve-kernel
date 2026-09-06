#!/usr/bin/env bash
# Prepare a disposable Debian guest which installs only the exact cached PVE
# kernel and headers.  Everything generated lives under artifacts/.
set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
artifact_dir=${PVE_VM_ARTIFACT_DIR:-"$script_dir/artifacts"}
cache_dir=${PVE_PACKAGE_CACHE:-/home/tanner/.cache/pve-zram-evidence/packages}
image_name=debian-13-genericcloud-amd64.qcow2
image_url="https://cloud.debian.org/images/cloud/trixie/latest/$image_name"
sums_url=https://cloud.debian.org/images/cloud/trixie/latest/SHA512SUMS
kernel=proxmox-kernel-7.0.14-16-pve_7.0.14-16_amd64.deb
headers=proxmox-headers-7.0.14-16-pve_7.0.14-16_amd64.deb

mkdir -p "$artifact_dir"
for command in curl sha512sum sha256sum qemu-img genisoimage; do
  command -v "$command" >/dev/null || { echo "missing required command: $command" >&2; exit 1; }
done

for package in "$kernel" "$headers"; do
  test -f "$cache_dir/$package" || { echo "missing authenticated cached package: $cache_dir/$package" >&2; exit 1; }
done

# These values are the exact pve-test Packages SHA-256 values recorded in the
# repository evidence plan.  Refuse a cache substitution before making media.
printf '%s  %s\n' \
  '71b3dc93d44390b8b597f04a97106483c46f2d1ee26ce4754a207e072b400f01' "$cache_dir/$kernel" \
  '21e15b544688249229f9ad7830625e9e5f31554f13c00c6d1a48e381b19c49cd' "$cache_dir/$headers" \
  | sha256sum -c -

curl --fail --location --proto '=https' --tlsv1.2 --retry 3 --output "$artifact_dir/SHA512SUMS" "$sums_url"
grep "  $image_name$" "$artifact_dir/SHA512SUMS" >"$artifact_dir/$image_name.SHA512"
if test ! -f "$artifact_dir/$image_name"; then
  curl --fail --location --proto '=https' --tlsv1.2 --retry 3 --output "$artifact_dir/$image_name" "$image_url"
fi
(cd "$artifact_dir" && sha512sum -c "$image_name.SHA512")

qemu-img create -f qcow2 -F qcow2 -b "$image_name" "$artifact_dir/pve-zram-overlay.qcow2"
mkdir -p "$artifact_dir/seed"
cp "$cache_dir/$kernel" "$cache_dir/$headers" "$artifact_dir/seed/"
(cd "$artifact_dir/seed" && sha256sum "$kernel" "$headers") >"$artifact_dir/seed/package-sha256sums.txt"
cat >"$artifact_dir/seed/meta-data" <<'EOF'
instance-id: pve-zram-7.0.14-16
local-hostname: pve-zram-7-0-14-16
EOF
cat >"$artifact_dir/seed/user-data" <<'EOF'
#cloud-config
ssh_pwauth: false
disable_root: true
users:
  - default
  - name: pveprobe
    groups: [sudo]
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
write_files:
  - path: /usr/local/sbin/pve-zram-probe
    permissions: '0755'
    content: |
      #!/bin/sh
      set -u
      out=/var/log/pve-zram-probe.log
      exec >>"$out" 2>&1
      echo '=== pve-zram isolated VM evidence ==='
      date -u --iso-8601=seconds
      uname -a
      uname -r
      dpkg-query -W -f='${Package} ${Version} ${Status}\n' 'proxmox-kernel-7.0.14-16-pve' 'proxmox-headers-7.0.14-16-pve' || true
      config=/boot/config-$(uname -r)
      printf 'config=%s\n' "$config"
      grep -E '^(CONFIG_ZRAM|CONFIG_ZRAM_MULTI_COMP)=' "$config" || true
      modinfo -k "$(uname -r)" zram || true
      modprobe zram || true
      lsmod | grep '^zram ' || true
      test -e /sys/module/zram && echo 'zram_module_loaded=yes' || echo 'zram_module_loaded=no'
      find "/lib/modules/$(uname -r)" -type f -path '*zram*' -printf '%p\n' 2>/dev/null || true
      echo '=== end evidence ==='
  - path: /etc/systemd/system/pve-zram-probe.service
    permissions: '0644'
    content: |
      [Unit]
      Description=Capture exact PVE ZRAM kernel evidence then stop the disposable VM
      After=multi-user.target
      [Service]
      Type=oneshot
      ExecStart=/usr/local/sbin/pve-zram-probe
      ExecStartPost=/usr/bin/systemctl --no-block poweroff
      [Install]
      WantedBy=multi-user.target
runcmd:
  - [ sh, -ec, 'mkdir -p /opt/pve-zram-packages && cp /var/lib/cloud/seed/nocloud/proxmox-*.deb /opt/pve-zram-packages/ && sha256sum -c /var/lib/cloud/seed/nocloud/package-sha256sums.txt' ]
  - [ sh, -ec, 'DEBIAN_FRONTEND=noninteractive apt-get update' ]
  - [ sh, -ec, 'DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends /opt/pve-zram-packages/proxmox-kernel-7.0.14-16-pve_7.0.14-16_amd64.deb /opt/pve-zram-packages/proxmox-headers-7.0.14-16-pve_7.0.14-16_amd64.deb' ]
  - [ sh, -ec, 'systemctl enable pve-zram-probe.service && sync && systemctl reboot' ]
EOF
rm -f "$artifact_dir/pve-zram-seed.iso"
genisoimage -quiet -output "$artifact_dir/pve-zram-seed.iso" -volid CIDATA -joliet -rock "$artifact_dir/seed"
sha256sum "$artifact_dir/$image_name" "$artifact_dir/pve-zram-overlay.qcow2" "$artifact_dir/pve-zram-seed.iso" >"$artifact_dir/media-sha256sums.txt"
printf '%s\n' "prepared: $artifact_dir"
