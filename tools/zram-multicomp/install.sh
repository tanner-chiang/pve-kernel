#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
META=${META:-$ROOT/metadata.env}
MODULE=${MODULE:-$ROOT/module/zram.ko}

[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 1; }
[[ -f "$META" ]] || { echo "missing $META" >&2; exit 2; }
[[ -f "$MODULE" ]] || { echo "missing $MODULE" >&2; exit 2; }

read_metadata() {
  local file=$1 key=$2 value
  value=$(sed -n "s/^${key}=\"\\(.*\\)\"$/\\1/p" "$file" | head -n1)
  printf '%s' "$value"
}

KVER=$(read_metadata "$META" KVER)
VERMAGIC=$(read_metadata "$META" VERMAGIC)

if [[ ! "$KVER" =~ ^[0-9]+\.[0-9]+\.[0-9]+-[0-9]+-pve$ ]]; then
  echo "invalid KVER in metadata: $KVER" >&2
  exit 2
fi

TARGET="/lib/modules/$KVER/updates/pve-zram-multicomp"
STOCK="/lib/modules/$KVER/kernel/drivers/block/zram/zram.ko"

[[ -d "/lib/modules/$KVER" && -e "/boot/vmlinuz-$KVER" ]] || {
  echo "target kernel $KVER is not installed" >&2
  exit 3
}

actual_vermagic=$(modinfo -F vermagic "$MODULE")
if [[ "$actual_vermagic" != "$VERMAGIC" ]]; then
  echo "refusing to install: module vermagic is '$actual_vermagic', expected '$VERMAGIC'" >&2
  exit 4
fi

if [[ -e "$TARGET/zram.ko" ]]; then
  echo "refusing to overwrite existing override: $TARGET/zram.ko" >&2
  echo "run uninstall.sh first" >&2
  exit 5
fi

secure_boot_enabled=false
if command -v mokutil >/dev/null 2>&1 && mokutil --sb-state 2>/dev/null | grep -q 'SecureBoot enabled'; then
  secure_boot_enabled=true
fi
if [[ -r /sys/module/module/parameters/sig_enforce ]] && grep -q '^Y$' /sys/module/module/parameters/sig_enforce; then
  secure_boot_enabled=true
fi

signer=$(modinfo -F signer "$MODULE")
if [[ "$secure_boot_enabled" == true && -z "$signer" ]]; then
  echo "refusing to install an unsigned module while Secure Boot or module signature enforcement is enabled" >&2
  exit 6
fi

rollback() {
  rm -f "$TARGET/zram.ko"
  rmdir --ignore-fail-on-non-empty "$TARGET" 2>/dev/null || true
  depmod -a "$KVER"
  if command -v update-initramfs >/dev/null 2>&1 && [[ -e "/boot/initrd.img-$KVER" ]]; then
    update-initramfs -u -k "$KVER" || true
  fi
}

if [[ ! -e "$STOCK" && ! -e "$STOCK.zst" && ! -e "$STOCK.xz" ]]; then
  echo "warning: stock zram module was not found at the usual path for $KVER" >&2
fi

install -d -m 0755 "$TARGET"
install -m 0644 "$MODULE" "$TARGET/zram.ko"
if ! depmod -a "$KVER"; then
  rollback
  echo "depmod failed; rolled back override" >&2
  exit 7
fi

resolved=$(modinfo -k "$KVER" -n zram 2>/dev/null || true)
if [[ "$resolved" != "$TARGET/zram.ko" ]]; then
  rollback
  echo "depmod did not select the override module (resolved: $resolved); rolled back" >&2
  exit 8
fi

if command -v update-initramfs >/dev/null 2>&1 && [[ -e "/boot/initrd.img-$KVER" ]]; then
  if ! update-initramfs -u -k "$KVER"; then
    rollback
    echo "update-initramfs failed; rolled back override" >&2
    exit 9
  fi
fi

cat <<EOF
Installed ZRAM multi-comp override for $KVER
  module: $TARGET/zram.ko
  resolved by modinfo: $resolved
  stock module: left untouched

If $KVER is the running kernel and zram is not in use, you may test with:
  modprobe -r zram
  modprobe zram
  test -e /sys/block/zram0/recomp_algorithm
  test -e /sys/block/zram0/recompress

Otherwise reboot into $KVER and verify those sysfs files.
Rollback:
  $ROOT/scripts/uninstall.sh
EOF
