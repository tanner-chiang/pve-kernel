#!/usr/bin/env bash
# Stop only the QEMU instance whose pidfile belongs to this artifact directory.
set -euo pipefail
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
artifact_dir=${PVE_VM_ARTIFACT_DIR:-"$script_dir/artifacts"}
pidfile="$artifact_dir/qemu.pid"
test -r "$pidfile" || { echo 'VM is not running (no task-owned pid file)'; exit 0; }
pid=$(cat "$pidfile")
case "$pid" in ''|*[!0-9]*) echo 'refusing malformed pid file' >&2; exit 1;; esac
if test -r "/proc/$pid/cmdline" && tr '\0' ' ' <"/proc/$pid/cmdline" | grep -Fq 'process=pve-zram-evidence'; then
  kill -TERM "$pid"
  echo "sent TERM to task-owned QEMU pid $pid"
else
  echo "refusing pid $pid: it is not the pve-zram evidence QEMU" >&2
  exit 1
fi
