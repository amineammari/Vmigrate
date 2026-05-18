#!/usr/bin/env bash
# Force libguestfs/virt-v2v qemu appliances to run single-vCPU TCG.
set -euo pipefail

if [[ -n "${VM_MIGRATOR_QEMU_WRAPPER_LOG:-/tmp/vm-migrator-qemu-wrapper.log}" ]]; then
  printf '%q ' /usr/bin/qemu-system-x86_64 -smp 1 "$@" >>"${VM_MIGRATOR_QEMU_WRAPPER_LOG:-/tmp/vm-migrator-qemu-wrapper.log}" 2>/dev/null || true
  printf '\n' >>"${VM_MIGRATOR_QEMU_WRAPPER_LOG:-/tmp/vm-migrator-qemu-wrapper.log}" 2>/dev/null || true
fi

exec /usr/bin/qemu-system-x86_64 -smp 1 "$@"
