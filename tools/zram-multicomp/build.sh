#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PVE_TREE=${1:?usage: build.sh <pve-kernel-tree> <output-dir>}
OUT_DIR=${2:?usage: build.sh <pve-kernel-tree> <output-dir>}
ARCH=${ARCH:-amd64}
PVE_DIST=${PVE_DIST:-trixie}
PVE_REPO=${PVE_REPO:-pve-no-subscription}
PVE_MIRROR=${PVE_MIRROR:-https://mirrors.ustc.edu.cn/proxmox/debian/pve}
UBUNTU_KERNEL_GIT=${UBUNTU_KERNEL_GIT:-https://git.proxmox.com/git/mirror_ubuntu-kernels.git}
CC=${CC:-gcc-14}
HOSTCC=${HOSTCC:-gcc-14}

mkdir -p "$OUT_DIR"
OUT_DIR=$(realpath "$OUT_DIR")
PVE_TREE=$(realpath "$PVE_TREE")

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing command: $1" >&2; exit 2; }; }
for cmd in awk curl dpkg-deb git gzip make modinfo modprobe patch sed sha256sum tar zstd; do need "$cmd"; done

cd "$PVE_TREE"

read_make_var() {
  local key=$1
  awk -F= -v key="$key" '$1 == key { sub(/^[^=]*=/, ""); gsub(/[[:space:]]/, ""); print; exit }' Makefile
}

KERNEL_MAJ=$(read_make_var KERNEL_MAJ)
KERNEL_MIN=$(read_make_var KERNEL_MIN)
KERNEL_PATCHLEVEL=$(read_make_var KERNEL_PATCHLEVEL)
KREL=$(read_make_var KREL)
KREL_EXTRA=$(read_make_var KREL_EXTRA)
KERNEL_VER="${KERNEL_MAJ}.${KERNEL_MIN}.${KERNEL_PATCHLEVEL}"
KVER="${KERNEL_VER}-${KREL}${KREL_EXTRA}-pve"
PVE_SHA=$(git rev-parse HEAD)
UBUNTU_SHA=$(git ls-tree HEAD submodules/ubuntu-kernel | awk '{print $3}')

AUTOMATION_SHA=$(git -C "$SCRIPT_DIR" rev-parse HEAD)

if [[ -z "$UBUNTU_SHA" ]]; then
  echo "cannot resolve ubuntu-kernel gitlink from $PVE_SHA" >&2
  exit 3
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$OUT_DIR"
OUT_DIR=$(realpath "$OUT_DIR")

PACKAGES_URL="$PVE_MIRROR/dists/$PVE_DIST/$PVE_REPO/binary-$ARCH/Packages.gz"
echo "Resolving official headers for $KVER from $PACKAGES_URL"
curl -fsSL "$PACKAGES_URL" -o "$WORK/Packages.gz"
gzip -dc "$WORK/Packages.gz" > "$WORK/Packages"

HEADER_PKG="proxmox-headers-$KVER"
FILENAME=$(awk -v pkg="$HEADER_PKG" '
  BEGIN { RS=""; FS="\n" }
  $0 ~ "(^|\n)Package: " pkg "(\n|$)" {
    for (i=1; i<=NF; i++) if ($i ~ /^Filename: /) { sub(/^Filename: /, "", $i); print $i; exit }
  }
' "$WORK/Packages")
HEADER_SHA256=$(awk -v pkg="$HEADER_PKG" '
  BEGIN { RS=""; FS="\n" }
  $0 ~ "(^|\n)Package: " pkg "(\n|$)" {
    for (i=1; i<=NF; i++) if ($i ~ /^SHA256: /) { sub(/^SHA256: /, "", $i); print $i; exit }
  }
' "$WORK/Packages")

if [[ -z "$FILENAME" ]]; then
  echo "Official package $HEADER_PKG is not published in $PVE_REPO yet." >&2
  exit 75
fi

HEADER_DEB="$WORK/headers.deb"
curl -fsSL "$PVE_MIRROR/$FILENAME" -o "$HEADER_DEB"
actual_sha256=$(sha256sum "$HEADER_DEB" | awk '{print $1}')
if [[ "$actual_sha256" != "$HEADER_SHA256" ]]; then
  echo "headers package checksum mismatch: expected $HEADER_SHA256, got $actual_sha256" >&2
  exit 8
fi
dpkg-deb -x "$HEADER_DEB" "$WORK/headers"
KDIR="$WORK/headers/usr/src/linux-headers-$KVER"

if [[ ! -f "$KDIR/Module.symvers" || ! -f "$KDIR/.config" ]]; then
  echo "headers package does not contain Module.symvers/.config for $KVER" >&2
  exit 4
fi

# Fetch the exact Ubuntu kernel commit referenced by this PVE revision.
echo "Fetching Ubuntu kernel source $UBUNTU_SHA"
git init -q "$WORK/ubuntu-kernel"
git -C "$WORK/ubuntu-kernel" remote add origin "$UBUNTU_KERNEL_GIT"
git -C "$WORK/ubuntu-kernel" fetch --depth=1 origin "$UBUNTU_SHA"
git -C "$WORK/ubuntu-kernel" checkout -q --detach FETCH_HEAD

# Apply the exact Proxmox patch stack from the selected PVE revision.
for p in "$PVE_TREE"/patches/kernel/*.patch; do
  [[ -e "$p" ]] || continue
  echo "Applying $(basename "$p")"
  patch --batch -d "$WORK/ubuntu-kernel" -p1 < "$p"
done

MODSRC="$WORK/zram-module"
mkdir -p "$MODSRC"
cp -a "$WORK/ubuntu-kernel/drivers/block/zram/." "$MODSRC/"

# Convert the in-tree Kbuild file into an external-module Kbuild file while
# preserving the official backend selection from the target headers config.
sed -i -E 's/^obj-\$\(CONFIG_ZRAM\)[[:space:]]*\+=[[:space:]]*zram\.o/obj-m += zram.o/' "$MODSRC/Makefile"
if ! grep -q '^obj-m[[:space:]]*+=[[:space:]]*zram\.o' "$MODSRC/Makefile"; then
  echo 'obj-m += zram.o' >> "$MODSRC/Makefile"
fi

# CONFIG_ZRAM_MULTI_COMP only gates code inside the zram module. The stock
# Proxmox headers deliberately have it disabled, so compile this one module
# with the feature macro enabled while retaining the exact official
# Module.symvers and all other target-kernel config values.
if ! grep -q '^CONFIG_ZRAM_MULTI_COMP=y$' "$KDIR/.config"; then
  printf '\nccflags-y += -DCONFIG_ZRAM_MULTI_COMP=1\n' >> "$MODSRC/Makefile"
fi

make -C "$KDIR" M="$MODSRC" CC="$CC" HOSTCC="$HOSTCC" modules
MODULE="$MODSRC/zram.ko"
[[ -s "$MODULE" ]] || { echo "zram.ko was not produced" >&2; exit 5; }

VERMAGIC=$(modinfo -F vermagic "$MODULE")
if [[ "${VERMAGIC%% *}" != "$KVER" ]]; then
  echo "vermagic mismatch: expected $KVER, got $VERMAGIC" >&2
  exit 6
fi

while read -r expected_crc symbol; do
  if ! grep -q "^${expected_crc}[[:space:]]${symbol}[[:space:]]" "$KDIR/Module.symvers"; then
    echo "module version mismatch for symbol ${symbol}: expected ${expected_crc}" >&2
    exit 7
  fi
done < <(modprobe --dump-modversions "$MODULE")

PKGDIR="$WORK/package"
mkdir -p "$PKGDIR/module" "$PKGDIR/scripts"
cp "$MODULE" "$PKGDIR/module/zram.ko"
cp "$SCRIPT_DIR/install.sh" "$PKGDIR/scripts/install.sh"
cp "$SCRIPT_DIR/uninstall.sh" "$PKGDIR/scripts/uninstall.sh"
chmod +x "$PKGDIR/scripts/"*.sh

cat > "$PKGDIR/metadata.env" <<EOF
KVER="$KVER"
PVE_SHA="$PVE_SHA"
UBUNTU_KERNEL_SHA="$UBUNTU_SHA"
AUTOMATION_SHA="$AUTOMATION_SHA"
VERMAGIC="$VERMAGIC"
CONFIG_ZRAM_MULTI_COMP=y
EOF
cp "$PKGDIR/metadata.env" "$OUT_DIR/metadata.env"

ARCHIVE="$OUT_DIR/zram-multicomp-$KVER.tar.zst"
tar -C "$PKGDIR" -cf - . | zstd -T0 -19 -o "$ARCHIVE"
(
  cd "$OUT_DIR"
  sha256sum "$(basename "$ARCHIVE")" > "$(basename "$ARCHIVE").sha256"
)

printf '\nBuilt %s\nPVE commit: %s\nUbuntu kernel commit: %s\nvermagic: %s\n' \
  "$ARCHIVE" "$PVE_SHA" "$UBUNTU_SHA" "$VERMAGIC"
