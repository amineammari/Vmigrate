#!/usr/bin/env bash
# Expose the embedded kernel/modules to libguestfs inside the running container.
set -euo pipefail

embed_root="${EMBEDDED_KERNEL_ROOT:-/usr/lib/vm-migrator/kernels}"
version_file="${embed_root}/kernel-version"
vmlinuz="${embed_root}/vmlinuz"

if [[ ! -r "${vmlinuz}" ]]; then
  echo "setup-embedded-kernel: missing ${vmlinuz}" >&2
  exit 1
fi

export SUPERMIN_KERNEL="${SUPERMIN_KERNEL:-${vmlinuz}}"

if [[ -f "${version_file}" ]]; then
  kver="$(tr -d '[:space:]' <"${version_file}")"
  if [[ -n "${kver}" && -d "${embed_root}/modules/${kver}" ]]; then
    mkdir -p "/lib/modules"
    if [[ ! -e "/lib/modules/${kver}" ]]; then
      ln -sf "${embed_root}/modules/${kver}" "/lib/modules/${kver}"
    fi
  fi
fi

export LIBGUESTFS_ENABLE_COREDUMP="${LIBGUESTFS_ENABLE_COREDUMP:-0}"
