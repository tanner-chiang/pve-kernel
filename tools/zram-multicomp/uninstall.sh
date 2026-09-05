#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
META=${META:-$ROOT/metadata.env}

[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 1; }
[[ -f "$META" ]] || { echo "missing $META" >&2; exit 2; }

read_metadata() {
  local file=$1 key=$2 value
  value=$(sed -n "s/^${key}=\"\\(.*\\)\"$/\\1/p" "$file" | head -n1)
  printf '%s' "$value"
}

KVER=$(read_metadata "$META" KVER)

if [[ ! "$KVER" =~ ^[0-9]+\.[0-9]+\.[0-9]+-[0-9]+-pve$ ]]; then
  echo "invalid KVER in metadata: $KVER" >&2
  exit 2
fi

TARGET="/lib/modules/$KVER/updates/pve-zram-multicomp"

if [[ ! -e "$TARGET/zram.ko" ]]; then
  echo "No override module installed for $KVER"
  exit 0
fi

backup=$(mktemp)
cp "$TARGET/zram.ko" "$backup"
rollback() {
  install -d -m 0755 "$TARGET"
  install -m 0644 "$backup" "$TARGET/zram.ko"
  depmod -a "$KVER"
  if command -v update-initramfs >/dev/null 2>&1 && [[ -e "/boot/initrd.img-$KVER" ]]; then
    update-initramfs -u -k "$KVER" || true
  fi
  rm -f "$backup"
}

rm -f "$TARGET/zram.ko"
rmdir --ignore-fail-on-non-empty "$TARGET" 2>/dev/null || true

if ! depmod -a "$KVER"; then
  rollback
  echo "depmod failed; restored override" >&2
  exit 3
fi

if command -v update-initramfs >/dev/null 2>&1 && [[ -e "/boot/initrd.img-$KVER" ]]; then
  if ! update-initramfs -u -k "$KVER"; then
    rollback
    echo "update-initramfs failed; restored override" >&2
    exit 4
  fi
fi

rm -f "$backup"

resolved=$(modinfo -k "$KVER" -n zram 2>/dev/null || true)
printf 'Removed override for %s\nResolved zram module: %s\n' "$KVER" "${resolved:-not found}"
