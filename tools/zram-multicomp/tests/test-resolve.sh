#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
FIXTURE="$ROOT/tests/fixtures/target-7.0.14-16"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
replace_hashes() {
  local manifest=$1
  sed -i -e "s/SOURCE_SHA/$(sha256sum "$FIXTURE/packages/kernel/usr/share/doc/proxmox-kernel-7.0.14-16-pve/SOURCE" | awk '{print $1}')/" -e "s/CONFIG_SHA/$(sha256sum "$FIXTURE/packages/headers/usr/src/linux-headers-7.0.14-16-pve/.config" | awk '{print $1}')/" -e "s/SYMVERS_SHA/$(sha256sum "$FIXTURE/packages/headers/usr/src/linux-headers-7.0.14-16-pve/Module.symvers" | awk '{print $1}')/" "$manifest"
}
run_resolve() {
  "$ROOT/resolve.sh" --fixture --kver 7.0.14-16-pve --arch amd64 --kernel-package proxmox-kernel-7.0.14-16-pve=7.0.14-16 --release-manifest "$1" --package-root "$2" --cache-dir "$WORK/cache" --output "$3"
}
manifest="$WORK/release.json"; cp "$FIXTURE/release.json" "$manifest"; replace_hashes "$manifest"
run_resolve "$manifest" "$FIXTURE/packages" "$WORK/target.json"
jq -e '.resolution_status == "fixture-ready" and .target.kver == "7.0.14-16-pve" and .source.ubuntu_kernel_commit == "68d75f0820869e33326712a9547550961795eaaf" and (.source.patches | length == 2)' "$WORK/target.json" >/dev/null
# Same KVER with a distinct Debian package revision is selected only when its
# complete NAME=VERSION identity is supplied; no "closest" revision is used.
revised="$WORK/revised.json"; jq '.packages += [(.packages[0] | .version = "7.0.14-16.1" | .sha256 = "9999999999999999999999999999999999999999999999999999999999999999"), (.packages[1] | .version = "7.0.14-16.1" | .sha256 = "8888888888888888888888888888888888888888888888888888888888888888")]' "$manifest" > "$revised"
"$ROOT/resolve.sh" --fixture --kver 7.0.14-16-pve --arch amd64 --kernel-package proxmox-kernel-7.0.14-16-pve=7.0.14-16.1 --release-manifest "$revised" --package-root "$FIXTURE/packages" --cache-dir "$WORK/cache" --output "$WORK/revised-target.json"
jq -e '.target.kernel_package.version == "7.0.14-16.1" and .target.kernel_package.sha256 == "9999999999999999999999999999999999999999999999999999999999999999"' "$WORK/revised-target.json" >/dev/null
if "$ROOT/resolve.sh" --fixture --kver 7.0.14-15-pve --arch amd64 --kernel-package proxmox-kernel-7.0.14-16-pve=7.0.14-16 --release-manifest "$manifest" --package-root "$FIXTURE/packages" --cache-dir "$WORK/cache" --output "$WORK/wrong-krel.json"; then exit 1; fi
jq -e '.resolution_status == "unsupported"' "$WORK/wrong-krel.json" >/dev/null
# The parser retains a KREL_EXTRA instead of silently trimming it to 7.0.14.
if "$ROOT/resolve.sh" --fixture --kver 7.0.14-16~bpo1-pve --arch amd64 --kernel-package proxmox-kernel-7.0.14-16-pve=7.0.14-16 --release-manifest "$manifest" --package-root "$FIXTURE/packages" --cache-dir "$WORK/cache" --output "$WORK/krel-extra.json"; then exit 1; fi
jq -e '.resolution_status == "unsupported"' "$WORK/krel-extra.json" >/dev/null
if "$ROOT/resolve.sh" --kver 7.0.14-16-pve --arch amd64 --kernel-package proxmox-kernel-7.0.14-16-pve=7.0.14-16 --release-manifest "$manifest" --package-root "$FIXTURE/packages" --cache-dir "$WORK/cache" --output "$WORK/fake-trust.json"; then exit 1; fi
signed="$WORK/signed.json"; jq '.packages[0].name = "proxmox-kernel-7.0.14-16-pve-signed" | .packages[0].signed = true' "$manifest" > "$signed"
"$ROOT/resolve.sh" --fixture --kver 7.0.14-16-pve --arch amd64 --kernel-package proxmox-kernel-7.0.14-16-pve-signed=7.0.14-16 --release-manifest "$signed" --package-root "$FIXTURE/packages" --cache-dir "$WORK/cache" --output "$WORK/signed-target.json"
jq -e '.target.kernel_package.signed == true' "$WORK/signed-target.json" >/dev/null
missing_root="$WORK/missing"; mkdir -p "$missing_root"; cp -a "$FIXTURE/packages/kernel" "$missing_root/kernel"
if run_resolve "$manifest" "$missing_root" "$WORK/waiting.json"; then exit 1; else [[ $? -eq 75 ]]; fi
jq -e '.resolution_status == "waiting-headers" and .headers.install_request.package == "proxmox-headers-7.0.14-16-pve" and .headers.install_request.version == "7.0.14-16"' "$WORK/waiting.json" >/dev/null
# Fixture waiting manifests are explicitly refused by ensure-headers, even
# for dry-run printout, because real apt-secure handling is Phase 3 work.
if "$ROOT/ensure-headers.sh" "$WORK/waiting.json" > "$WORK/header-command" 2>"$WORK/header-stderr"; then
  cat "$WORK/header-stderr" >&2
  exit 1
fi
grep -F 'fixture manifests can never install headers' "$WORK/header-stderr" >/dev/null
missing_source="$WORK/no-source"; cp -a "$FIXTURE/packages" "$missing_source"; rm "$missing_source/kernel/usr/share/doc/proxmox-kernel-7.0.14-16-pve/SOURCE"
if run_resolve "$manifest" "$missing_source" "$WORK/no-source.json"; then exit 1; fi
echo 'resolver fixture tests passed'
