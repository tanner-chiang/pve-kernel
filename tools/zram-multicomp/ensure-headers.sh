#!/usr/bin/env bash
# This independent CLI is deliberately not a kernel postinst hook.  It only
# installs the exact package/version declared by a waiting target manifest.
# apt-get syntax follows apt-get(8): install pkg=version.
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/lib/common.sh"
[[ ${DPKG_MAINTSCRIPT_PACKAGE-} == '' ]] || die 2 'refusing to run from a dpkg maintainer script'
[[ $# -ge 1 && $# -le 2 ]] || die 2 'usage: ensure-headers.sh target.json [--install]'
TARGET=$1
validate_target_json "$TARGET" || die 2 'invalid target manifest'
[[ $(jq -r '.resolution_status' "$TARGET") == waiting-headers ]] || die 2 'target is not waiting for headers'
[[ $(jq -r '.trust.mode // ""' "$TARGET") != fixture-only ]] || die 2 'fixture manifests can never install headers'
pkg=$(jq -r '.headers.install_request.package' "$TARGET")
version=$(jq -r '.headers.install_request.version' "$TARGET")
[[ $pkg =~ ^proxmox-headers-[A-Za-z0-9.+~:-]+$ && $version != null ]] || die 75 'no exact headers package/version is available yet'
if [[ ${2-} != --install ]]; then printf 'apt-get install %s=%s\n' "$pkg" "$version"; exit 0; fi
die 75 'headers installation remains disabled until G3 package-lock validation is complete'
