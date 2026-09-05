#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
META=${META:-$ROOT/metadata.env}
MODULE=${MODULE:-$ROOT/module/zram.ko}

[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 1; }
[[ -f "$META" ]] || { echo "missing $META" >&2; exit 2; }
[[ -f "$MODULE" ]] || { echo "missing $MODULE" >&2; exit 2; }

# shellcheck disable=SC1090
source "$META"
: "${KVER:?missing KVER in metadata}"

TARGET="/lib/modules/$KVER/updates/pve-zram-multicomp"
STOCK="/lib/modules/$KVER/kernel/drivers/block/zram/zram.ko"

[[ -d "/lib/modules/$KVER" ]] || {
  echo "target kernel $KVER is not installed" >&2
  exit 3
}

actual=$(modinfo -F vermagic "$MODULE")
if [[ "${actual%% *}" != "$KVER" ]]; then
  echo "refusing to install: module vermagic is '$actual', expected '$KVER ...'" >&2
  exit 4
fi

if [[ ! -e "$STOCK" && ! -e "$STOCK.zst" && ! -e "$STOCK.xz" ]]; then
  echo "warning: stock zram module was not found at the usual path for $KVER" >&2
fi

install -d -m 0755 "$TARGET"
install -m 0644 "$MODULE" "$TARGET/zram.ko"
depmod -a "$KVER"

resolved=$(modinfo -k "$KVER" -n zram 2>/dev/null || true)
if [[ "$resolved" != "$TARGET/zram.ko" ]]; then
  rm -f "$TARGET/zram.ko"
  rmdir --ignore-fail-on-non-empty "$TARGET" 2>/dev/null || true
  depmod -a "$KVER"
  echo "depmod did not select the override module (resolved: $resolved); rolled back" >&2
  exit 5
fi

if command -v update-initramfs >/dev/null 2>&1 && [[ -e "/boot/initrd.img-$KVER" ]]; then
  update-initramfs -u -k "$KVER"
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
