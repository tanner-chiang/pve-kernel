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

if [[ ! "$KVER" =~ ^[0-9]+\.[0-9]+\.[0-9]+-[0-9]+[A-Za-z0-9+._~-]*-pve$ ]]; then
  echo "invalid KVER in metadata: $KVER" >&2
  exit 2
fi

TARGET="/lib/modules/$KVER/updates/pve-zram-multicomp"

refresh_module_index() {
  if ! depmod -a "$KVER"; then
    return 10
  fi
  if command -v update-initramfs >/dev/null 2>&1 && [[ -e "/boot/initrd.img-$KVER" ]]; then
    update-initramfs -u -k "$KVER"
  fi
}

rollback() {
  install -d -m 0755 "$TARGET"
  install -m 0644 "$backup" "$TARGET/zram.ko"
  if ! refresh_module_index; then
    echo "rollback warning: could not rebuild module index or initramfs for $KVER" >&2
    return 11
  fi
}

if [[ ! -e "$TARGET/zram.ko" ]]; then
  echo "No override module installed for $KVER"
  if [[ -d "/lib/modules/$KVER" ]] && ! refresh_module_index; then
    echo "warning: could not rebuild module index or initramfs for $KVER" >&2
    exit 3
  fi
  exit 0
fi

backup=$(mktemp)
cp "$TARGET/zram.ko" "$backup"
rm -f "$TARGET/zram.ko"
rmdir --ignore-fail-on-non-empty "$TARGET" 2>/dev/null || true

if ! refresh_module_index; then
  rollback || exit 11
  echo "module index or initramfs refresh failed; restored override" >&2
  exit 3
fi

rm -f "$backup"

resolved=$(modinfo -k "$KVER" -n zram 2>/dev/null || true)
printf 'Removed override for %s\nResolved zram module: %s\n' "$KVER" "${resolved:-not found}"
