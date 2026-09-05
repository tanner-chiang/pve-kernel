#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
META=${META:-$ROOT/metadata.env}

[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 1; }
[[ -f "$META" ]] || { echo "missing $META" >&2; exit 2; }

# shellcheck disable=SC1090
source "$META"
: "${KVER:?missing KVER in metadata}"

TARGET="/lib/modules/$KVER/updates/pve-zram-multicomp"
rm -f "$TARGET/zram.ko"
rmdir --ignore-fail-on-non-empty "$TARGET" 2>/dev/null || true

depmod -a "$KVER"
if command -v update-initramfs >/dev/null 2>&1 && [[ -e "/boot/initrd.img-$KVER" ]]; then
  update-initramfs -u -k "$KVER"
fi

resolved=$(modinfo -k "$KVER" -n zram 2>/dev/null || true)
printf 'Removed override for %s\nResolved zram module: %s\n' "$KVER" "${resolved:-not found}"
