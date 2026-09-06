#!/usr/bin/env bash
# Resolve one exact PVE kernel package into the frozen Phase 1 target format.
# This Phase 1 entry point is fixture-only.  A JSON field is never evidence
# that apt-secure authenticated it; production must use the documented adapter.
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

usage() {
  cat >&2 <<'EOF'
usage: resolve.sh --kver KVER --arch ARCH --kernel-package NAME=VERSION \
  --release-manifest FILE --package-root DIR --cache-dir DIR --output target.json --fixture
EOF
  exit 2
}

KVER=''; ARCH=''; KERNEL_ID=''; RELEASE=''; PACKAGE_ROOT=''; CACHE_DIR=''; OUTPUT=''; FIXTURE=false
while [[ $# -gt 0 ]]; do
  case $1 in
    --kver) KVER=${2-}; shift 2 ;;
    --arch) ARCH=${2-}; shift 2 ;;
    --kernel-package) KERNEL_ID=${2-}; shift 2 ;;
    --release-manifest) RELEASE=${2-}; shift 2 ;;
    --package-root) PACKAGE_ROOT=${2-}; shift 2 ;;
    --cache-dir) CACHE_DIR=${2-}; shift 2 ;;
    --output) OUTPUT=${2-}; shift 2 ;;
    --fixture) FIXTURE=true; shift ;;
    *) usage ;;
  esac
done
[[ -n $KVER && -n $ARCH && -n $KERNEL_ID && -n $RELEASE && -n $PACKAGE_ROOT && -n $CACHE_DIR && -n $OUTPUT ]] || usage
[[ $FIXTURE == true ]] || die 2 'production resolution is disabled until an apt-secure evidence adapter is implemented'
is_pve_kver "$KVER" || die 2 "KVER must include the exact PVE release suffix: $KVER"
[[ $KERNEL_ID == *=* ]] || die 2 "--kernel-package must be NAME=VERSION"
KERNEL_NAME=${KERNEL_ID%%=*}; KERNEL_VERSION=${KERNEL_ID#*=}
[[ -n $KERNEL_NAME && -n $KERNEL_VERSION ]] || usage
for cmd in jq sha256sum awk; do need "$cmd"; done
[[ -f $RELEASE && -d $PACKAGE_ROOT ]] || die 2 "release manifest or package root is missing"
mkdir -p -- "$CACHE_DIR" "$(dirname -- "$OUTPUT")"

cache_target() {
  local key destination
  key=$(printf '%s\0%s\0%s\0%s' "$KVER" "$ARCH" "$KERNEL_NAME" "$KERNEL_VERSION" | sha256sum | awk '{print $1}')
  destination="$CACHE_DIR/$key"
  mkdir -p -- "$destination"
  cp -- "$OUTPUT" "$destination/target.json"
}

# `trust.verified_by` is retained only as fixture provenance.  Do not infer
# authentication from it; apt-secure(8) verification belongs before a future
# production adapter writes any resolver input.
jq -e --arg k "$KVER" --arg a "$ARCH" '
  .schema_version == 1 and .fixture == true and
  (.sources | type == "array") and
  (.packages | type == "array")
' "$RELEASE" >/dev/null || die 3 "untrusted or malformed release manifest"

kernel=$(jq -cer --arg n "$KERNEL_NAME" --arg v "$KERNEL_VERSION" --arg k "$KVER" --arg a "$ARCH" '
  [.packages[] | select(.kind == "kernel" and .name == $n and .version == $v and .kver == $k and .architecture == $a)] |
  if length == 1 then .[0] else empty end
' "$RELEASE") || {
  json_error unsupported "no unique exact kernel package identity for $KERNEL_ID / $KVER" > "$OUTPUT"
  exit 3
}
kernel_sha=$(jq -r '.sha256' <<<"$kernel")
is_sha256 "$kernel_sha" || die 3 "kernel package metadata lacks SHA-256"
source_rel=$(jq -r '.source_path' <<<"$kernel")
[[ $source_rel != null && $source_rel != /* && $source_rel != *".."* ]] || die 3 "unsafe kernel SOURCE path"
source_file="$PACKAGE_ROOT/$source_rel"
[[ -f $source_file ]] || {
  json_error unsupported "kernel SOURCE is unavailable for the exact package" > "$OUTPUT"; exit 3;
}
expected_source_sha=$(jq -r '.source_sha256' <<<"$kernel")
is_sha256 "$expected_source_sha" && [[ $(sha256_file "$source_file") == "$expected_source_sha" ]] || die 3 "kernel SOURCE checksum mismatch"
pve_commit=$(pve_commit_from_source "$source_file") || die 3 "kernel SOURCE has no exact PVE commit"

source_data=$(jq -cer --arg p "$pve_commit" --arg k "$KVER" '
  [.sources[] | select(.pve_commit == $p and .kver == $k)] | if length == 1 then .[0] else empty end
' "$RELEASE") || { json_error unsupported "no unique source mapping for PVE commit $pve_commit" > "$OUTPUT"; exit 3; }
ubuntu_commit=$(jq -r '.ubuntu_kernel_commit' <<<"$source_data")
snapshot_sha=$(jq -r '.source_snapshot_sha256' <<<"$source_data")
if ! is_commit "$ubuntu_commit" || ! is_sha256 "$snapshot_sha"; then die 3 "trusted source mapping is incomplete"; fi

headers=$(jq -cer --arg k "$KVER" --arg a "$ARCH" --arg v "$KERNEL_VERSION" '
  [.packages[] | select(.kind == "headers" and .kver == $k and .architecture == $a and .version == $v)] |
  if length == 1 then .[0] else empty end
' "$RELEASE") || headers=''
if [[ -z $headers ]]; then
  json_error unsupported "no unique exact headers package identity for $KVER" > "$OUTPUT"
  exit 3
fi
headers_sha=$(jq -r '.sha256' <<<"$headers"); is_sha256 "$headers_sha" || die 3 "headers package metadata lacks SHA-256"
headers_version=$(jq -r '.version' <<<"$headers"); [[ -n $headers_version && $headers_version != null ]] || die 3 'headers package metadata lacks version'
config_rel=$(jq -r '.config_path' <<<"$headers"); symvers_rel=$(jq -r '.module_symvers_path' <<<"$headers")
for rel in "$config_rel" "$symvers_rel"; do
  if [[ $rel == null || $rel == /* || $rel == *".."* || ! -f "$PACKAGE_ROOT/$rel" ]]; then
    jq -n --arg k "$KVER" --arg a "$ARCH" --argjson kernel "$kernel" --argjson headers "$headers" --argjson source "$source_data" --arg p "$pve_commit" --arg u "$ubuntu_commit" --arg s "$snapshot_sha" '
      {schema_version: 1, resolution_status: "waiting-headers", trust:{mode:"fixture-only"}, target: {kver: $k, architecture: $a, kernel_package: {name: $kernel.name, version: $kernel.version, sha256: $kernel.sha256, signed: ($kernel.signed // false)}}, headers: {status: "waiting", install_request: {package: $headers.name, version: $headers.version}}, source: {pve_commit: $p, ubuntu_kernel_commit: $u, patches: $source.patches, source_snapshot_sha256: $s}, integrity: {kernel_package_sha256: $kernel.sha256, headers_package_sha256: $headers.sha256, headers_config_sha256: null, module_symvers_sha256: null}, build: {toolchain: null, vermagic: null, artifact_sha256: null}}' > "$OUTPUT"
    validate_target_json "$OUTPUT" || die 3 "internal target schema failure"
    cache_target
    exit 75
  fi
done
config_sha=$(sha256_file "$PACKAGE_ROOT/$config_rel"); symvers_sha=$(sha256_file "$PACKAGE_ROOT/$symvers_rel")
[[ $config_sha == "$(jq -r '.config_sha256' <<<"$headers")" && $symvers_sha == "$(jq -r '.module_symvers_sha256' <<<"$headers")" ]] || die 3 "headers content checksum mismatch"

jq -n --arg k "$KVER" --arg a "$ARCH" --argjson kernel "$kernel" --argjson headers "$headers" --argjson source "$source_data" --arg c "$config_sha" --arg m "$symvers_sha" '
  {schema_version: 1, resolution_status: "fixture-ready", trust: {mode: "fixture-only"}, target: {kver: $k, architecture: $a, kernel_package: {name: $kernel.name, version: $kernel.version, sha256: $kernel.sha256, signed: ($kernel.signed // false)}}, headers: {status: "ready", package: {name: $headers.name, version: $headers.version, sha256: $headers.sha256}}, source: {pve_commit: $source.pve_commit, ubuntu_kernel_commit: $source.ubuntu_kernel_commit, patches: $source.patches, source_snapshot_sha256: $source.source_snapshot_sha256}, integrity: {kernel_package_sha256: $kernel.sha256, headers_package_sha256: $headers.sha256, headers_config_sha256: $c, module_symvers_sha256: $m}, build: {toolchain: null, vermagic: null, artifact_sha256: null}}' > "$OUTPUT"
validate_target_json "$OUTPUT" || die 3 "internal target schema failure"
cache_target
