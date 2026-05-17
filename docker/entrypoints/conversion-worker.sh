#!/usr/bin/env bash
set -Eeuo pipefail

source /usr/local/bin/setup-embedded-kernel-runtime || {
  echo "WARN: embedded kernel setup failed; libguestfs may not find a kernel." >&2
}

export LIBGUESTFS_BACKEND="${LIBGUESTFS_BACKEND:-direct}"
export LIBGUESTFS_BACKEND_SETTINGS="${LIBGUESTFS_BACKEND_SETTINGS:-force_tcg}"
export LIBGUESTFS_MEMSIZE="${LIBGUESTFS_MEMSIZE:-768}"
export LIBGUESTFS_CPUS="${LIBGUESTFS_CPUS:-1}"
export LIBGUESTFS_SMP="${LIBGUESTFS_CPUS}"
export VIRT_V2V_NBDKIT_THREADS="${VIRT_V2V_NBDKIT_THREADS:-1}"
export LIBGUESTFS_TOOLS_CONF="${LIBGUESTFS_TOOLS_CONF:-/etc/libguestfs-tools.conf}"

/usr/local/bin/write-libguestfs-tools-conf "${LIBGUESTFS_TOOLS_CONF}"

if [[ -n "${VMWARE_VDDK_LIBDIR:-}" ]]; then
  /usr/local/bin/vddk-sanitize-libcxx "${VMWARE_VDDK_LIBDIR}/lib64"
  export LD_LIBRARY_PATH="${VMWARE_VDDK_LIBDIR}/lib64${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
fi

if [[ -e /usr/lib/x86_64-linux-gnu/libstdc++.so.6 ]]; then
  export LD_PRELOAD="/usr/lib/x86_64-linux-gnu/libstdc++.so.6${LD_PRELOAD:+:$LD_PRELOAD}"
fi
if [[ -e /lib/x86_64-linux-gnu/libgcc_s.so.1 ]]; then
  export LD_PRELOAD="/lib/x86_64-linux-gnu/libgcc_s.so.1${LD_PRELOAD:+:$LD_PRELOAD}"
fi

plugin_dest="/usr/lib/x86_64-linux-gnu/nbdkit/plugins/nbdkit-vddk-plugin.so"
if [[ -f /opt/vmware-vddk/lib64/libdiskLibPlugin.so && ! -f "${plugin_dest}" ]]; then
  mkdir -p "$(dirname "${plugin_dest}")"
  ln -sf /opt/vmware-vddk/lib64/libdiskLibPlugin.so "${plugin_dest}" || true
fi

if [[ "${SKIP_CONVERSION_PREFLIGHT:-false}" != "true" ]]; then
  if ! /usr/local/bin/conversion-worker-preflight; then
    if [[ "${PREFLIGHT_STRICT:-false}" == "true" ]]; then
      echo "ERROR: preflight failed and PREFLIGHT_STRICT=true" >&2
      exit 1
    fi
    echo "WARN: preflight reported errors; starting worker anyway (PREFLIGHT_STRICT=false)." >&2
  fi
fi

concurrency="${CELERY_WORKER_CONCURRENCY:-1}"
prefetch="${CELERY_WORKER_PREFETCH_MULTIPLIER:-1}"
max_tasks="${CELERY_WORKER_MAX_TASKS_PER_CHILD:-5}"
soft_limit="${CELERY_TASK_SOFT_TIME_LIMIT:-7200}"
hard_limit="${CELERY_TASK_TIME_LIMIT:-7500}"

exec "$@" \
  --concurrency="${concurrency}" \
  --prefetch-multiplier="${prefetch}" \
  --max-tasks-per-child="${max_tasks}" \
  --soft-time-limit="${soft_limit}" \
  --time-limit="${hard_limit}"
