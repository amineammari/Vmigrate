#!/usr/bin/env bash
set -Eeuo pipefail

# Setup VDDK environment BEFORE anything else so preflight can access it
if [[ -n "${VMWARE_VDDK_LIBDIR:-}" ]]; then
  # Prevent VDDK-bundled libstdc++/libgcc from conflicting with system libraries
  if [[ -d "${VMWARE_VDDK_LIBDIR}/lib64" ]]; then
    for _f in libstdc++.so libstdc++.so.* libgcc_s.so libgcc_s.so.*; do
      if [[ -e "${VMWARE_VDDK_LIBDIR}/lib64/$_f" ]]; then
        mv "${VMWARE_VDDK_LIBDIR}/lib64/$_f" "${VMWARE_VDDK_LIBDIR}/lib64/$_f.disabled" 2>/dev/null || true
      fi
    done
  fi
  export LD_LIBRARY_PATH="${VMWARE_VDDK_LIBDIR}/lib64:${LD_LIBRARY_PATH:-}"
fi

# Preload system libstdc++/libgcc to avoid conflicts with VDDK-bundled copies
if [[ -e "/usr/lib/x86_64-linux-gnu/libstdc++.so.6" ]]; then
  export LD_PRELOAD="/usr/lib/x86_64-linux-gnu/libstdc++.so.6${LD_PRELOAD:+:$LD_PRELOAD}"
fi
if [[ -e "/lib/x86_64-linux-gnu/libgcc_s.so.1" ]]; then
  export LD_PRELOAD="/lib/x86_64-linux-gnu/libgcc_s.so.1${LD_PRELOAD:+:$LD_PRELOAD}"
fi

# Create nbdkit VDDK plugin symlink (only if a real plugin isn't already installed)
PLUGIN_DEST="/usr/lib/x86_64-linux-gnu/nbdkit/plugins/nbdkit-vddk-plugin.so"
if [[ -f "/opt/vmware-vddk/lib64/libdiskLibPlugin.so" && ! -f "$PLUGIN_DEST" ]]; then
  mkdir -p /usr/lib/x86_64-linux-gnu/nbdkit/plugins || true
  ln -sf /opt/vmware-vddk/lib64/libdiskLibPlugin.so "$PLUGIN_DEST" || true
fi

if [[ "${SKIP_CONVERSION_PREFLIGHT:-false}" != "true" ]]; then
  /usr/local/bin/conversion-worker-preflight
fi

concurrency="${CELERY_WORKER_CONCURRENCY:-2}"
prefetch="${CELERY_WORKER_PREFETCH_MULTIPLIER:-1}"
max_tasks="${CELERY_WORKER_MAX_TASKS_PER_CHILD:-50}"
soft_limit="${CELERY_TASK_SOFT_TIME_LIMIT:-7200}"
hard_limit="${CELERY_TASK_TIME_LIMIT:-7500}"

# Ensure VDDK libraries are on LD_LIBRARY_PATH for runtime tools (virt-v2v, nbdkit)
if [[ -n "${VMWARE_VDDK_LIBDIR:-}" ]]; then
  # Prevent VDDK-bundled libstdc++/libgcc from conflicting with system libraries
  if [[ -d "${VMWARE_VDDK_LIBDIR}/lib64" ]]; then
    for _f in libstdc++.so libstdc++.so.* libgcc_s.so libgcc_s.so.*; do
      if [[ -e "${VMWARE_VDDK_LIBDIR}/lib64/$_f" ]]; then
        mv "${VMWARE_VDDK_LIBDIR}/lib64/$_f" "${VMWARE_VDDK_LIBDIR}/lib64/$_f.disabled" 2>/dev/null || true
      fi
    done
  fi
  export LD_LIBRARY_PATH="${VMWARE_VDDK_LIBDIR}/lib64:${LD_LIBRARY_PATH:-}"
fi

# Preload system libstdc++/libgcc to avoid conflicts with VDDK-bundled copies
if [[ -e "/usr/lib/x86_64-linux-gnu/libstdc++.so.6" ]]; then
  export LD_PRELOAD="/usr/lib/x86_64-linux-gnu/libstdc++.so.6${LD_PRELOAD:+:$LD_PRELOAD}"
fi
if [[ -e "/lib/x86_64-linux-gnu/libgcc_s.so.1" ]]; then
  export LD_PRELOAD="/lib/x86_64-linux-gnu/libgcc_s.so.1${LD_PRELOAD:+:$LD_PRELOAD}"
fi

# Create nbdkit VDDK plugin symlink (only if a real plugin isn't already installed)
PLUGIN_DEST="/usr/lib/x86_64-linux-gnu/nbdkit/plugins/nbdkit-vddk-plugin.so"
if [[ -f "/opt/vmware-vddk/lib64/libdiskLibPlugin.so" && ! -f "$PLUGIN_DEST" ]]; then
  mkdir -p /usr/lib/x86_64-linux-gnu/nbdkit/plugins || true
  ln -sf /opt/vmware-vddk/lib64/libdiskLibPlugin.so "$PLUGIN_DEST" || true
fi

exec "$@" \
  --concurrency="${concurrency}" \
  --prefetch-multiplier="${prefetch}" \
  --max-tasks-per-child="${max_tasks}" \
  --soft-time-limit="${soft_limit}" \
  --time-limit="${hard_limit}"
