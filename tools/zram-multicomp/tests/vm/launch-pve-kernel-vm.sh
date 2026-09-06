#!/usr/bin/env bash
# Start the isolated evidence VM. It writes a serial log and powers itself off
# after the second boot; no host block device or host network is passed through.
set -euo pipefail
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
artifact_dir=${PVE_VM_ARTIFACT_DIR:-"$script_dir/artifacts"}
for file in pve-zram-overlay.qcow2 pve-zram-seed.iso; do
  test -f "$artifact_dir/$file" || { echo "run prepare-pve-kernel-vm.sh first: missing $file" >&2; exit 1; }
done
test ! -e "$artifact_dir/qemu.pid" || { echo "VM pid file exists; run stop-pve-kernel-vm.sh first" >&2; exit 1; }
rm -f "$artifact_dir/serial.log" "$artifact_dir/qmp.sock"
exec qemu-system-x86_64 \
  -name pve-zram-evidence,process=pve-zram-evidence \
  -machine q35,accel=kvm:tcg -cpu host -smp 2 -m 3584 \
  -drive if=virtio,format=qcow2,file="$artifact_dir/pve-zram-overlay.qcow2" \
  -drive if=none,media=cdrom,readonly=on,file="$artifact_dir/pve-zram-seed.iso",id=seed \
  -device ich9-ahci,id=sata -device ide-cd,drive=seed,bus=sata.2 \
  -nic user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:22270-:22 \
  -display none -serial "file:$artifact_dir/serial.log" -monitor none \
  -qmp "unix:$artifact_dir/qmp.sock,server=on,wait=off" \
  -pidfile "$artifact_dir/qemu.pid"
