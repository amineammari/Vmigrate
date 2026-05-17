#!/usr/bin/env bash
# Embed a Debian kernel + modules inside the image for supermin/libguestfs (air-gapped).
set -euo pipefail

dest_root="${1:-/usr/lib/vm-migrator/kernels}"

if ! ls /boot/vmlinuz-* >/dev/null 2>&1; then
  echo "embed-container-kernel: no /boot/vmlinuz-* found" >&2
  exit 1
fi

kver="$(ls -1 /lib/modules 2>/dev/null | sort -V | tail -n1 || true)"
if [[ -z "${kver}" ]]; then
  echo "embed-container-kernel: no /lib/modules/* found" >&2
  exit 1
fi

kernel_src="/boot/vmlinuz-${kver}"
if [[ ! -r "${kernel_src}" ]]; then
  kernel_src="$(ls -1t /boot/vmlinuz-* | head -n1)"
  kver="${kernel_src##*/vmlinuz-}"
fi

mkdir -p "${dest_root}/modules"
install -D -m 0644 "${kernel_src}" "${dest_root}/vmlinuz"
echo "${kver}" > "${dest_root}/kernel-version"
rm -rf "${dest_root}/modules/${kver}"
cp -a "/lib/modules/${kver}" "${dest_root}/modules/${kver}"
chmod -R a+rX "${dest_root}"

echo "embed-container-kernel: installed ${kernel_src} (${kver}) under ${dest_root}"
