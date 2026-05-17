#!/usr/bin/env bash
# Disable VDDK-bundled libstdc++/libgcc that break guestfish/libguestfs (GLIBCXX_* mismatch).
set -euo pipefail

libdir="${1:-${VMWARE_VDDK_LIBDIR:-/opt/vmware-vddk}/lib64}"

if [[ ! -d "${libdir}" ]]; then
  echo "vddk-sanitize: ${libdir} not found, skipping." >&2
  exit 0
fi

for pattern in libstdc++.so libstdc++.so.* libgcc_s.so libgcc_s.so.*; do
  for path in "${libdir}"/${pattern}; do
    [[ -e "${path}" ]] || continue
    [[ "${path}" == *.disabled ]] && continue
    target="${path}.disabled"
    if [[ -e "${target}" ]]; then
      rm -f "${path}"
    else
      mv -f "${path}" "${target}"
    fi
    echo "vddk-sanitize: disabled ${path}"
  done
done
