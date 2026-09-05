# Proxmox ZRAM multi-comp module automation

This automation keeps the stock Proxmox kernel package intact and builds only an overriding `zram.ko` with `CONFIG_ZRAM_MULTI_COMP=y`.

## Design

For every selected upstream `proxmox/pve-kernel` revision the workflow:

1. resolves the exact PVE kernel release (`KVER`) from the upstream `Makefile`;
2. resolves the exact Ubuntu kernel gitlink referenced by that PVE revision;
3. fetches that source from the canonical Proxmox Ubuntu-kernel mirror;
4. applies the exact `patches/kernel/*.patch` stack from the PVE revision;
5. downloads the official `proxmox-headers-$KVER` package from the PVE no-subscription repository;
6. uses the official header tree, `.config`, and `Module.symvers` for ABI matching;
7. builds only `drivers/block/zram` as an external module while defining `CONFIG_ZRAM_MULTI_COMP=1` for that module;
8. rejects a result whose `vermagic` does not start with the exact target `KVER`;
9. packages the module with safe install/remove scripts and publishes a GitHub Actions artifact/release.

The stock module under:

```text
/lib/modules/<KVER>/kernel/drivers/block/zram/zram.ko*
```

is never modified. The custom module is installed at:

```text
/lib/modules/<KVER>/updates/pve-zram-multicomp/zram.ko
```

`depmod` must resolve `zram` to that path after installation; otherwise the installer removes the override immediately and exits with an error.

## Workflow triggers

- `workflow_dispatch`: build a specified upstream PVE ref (default `master`).
- schedule: check upstream every 6 hours; an already-published `KVER` is skipped.
- pull request: validates changes to the workflow or these scripts without publishing a release.

Scheduled workflows only run from the repository default branch, so the automation becomes active after the implementation PR is merged to `master`.

## Install on a PVE host

Download the release/archive that exactly matches the installed target kernel, for example `7.0.14-16-pve`.

```bash
sha256sum -c zram-multicomp-7.0.14-16-pve.tar.zst.sha256
mkdir zram-multicomp
cd zram-multicomp
tar --zstd -xf ../zram-multicomp-7.0.14-16-pve.tar.zst
sudo ./scripts/install.sh
```

Verify module resolution:

```bash
modinfo -k 7.0.14-16-pve -n zram
```

Expected path:

```text
/lib/modules/7.0.14-16-pve/updates/pve-zram-multicomp/zram.ko
```

After booting that kernel:

```bash
modprobe zram
test -e /sys/block/zram0/recomp_algorithm
test -e /sys/block/zram0/recompress
```

## Roll back

From the extracted package directory:

```bash
sudo ./scripts/uninstall.sh
```

This deletes only the overriding module, runs `depmod`, refreshes the target initramfs when present, and leaves the Proxmox stock module untouched.

## Failure behavior

If the official headers for a newly-pushed upstream PVE revision are not published yet, the scheduled build exits as a non-error skip and retries on the next schedule. Build, ABI, `vermagic`, or module-resolution failures never replace the stock module on a PVE host.

## Secure Boot

The GitHub-produced module is not signed with a host-trusted Secure Boot key. If Secure Boot module signature enforcement is enabled, sign `zram.ko` with a key trusted by that PVE host before installation/loading.
