#!/usr/bin/env bash
# Extract guest evidence without mounting or modifying its task-owned disk.
set -euo pipefail
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
artifact_dir=${PVE_VM_ARTIFACT_DIR:-"$script_dir/artifacts"}
serial="$artifact_dir/serial.log"
test -r "$serial" || { echo "missing serial log: $serial" >&2; exit 1; }
awk '/=== pve-zram isolated VM evidence ===/{show=1} show{print} /=== end evidence ===/{show=0}' "$serial"
