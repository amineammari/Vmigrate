#!/usr/bin/env bash
# Conversion worker preflight — errors block startup only when PREFLIGHT_STRICT=true.
set -Eeuo pipefail

errors=0
warnings=0
strict="${PREFLIGHT_STRICT:-false}"

fail() {
  echo "ERROR: $*" >&2
  errors=$((errors + 1))
}

warn() {
  echo "WARN: $*" >&2
  warnings=$((warnings + 1))
}

info() {
  echo "INFO: $*"
}

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    fail "Required environment variable ${name} is not set."
  fi
}

require_bin() {
  local name="$1"
  if ! command -v "${name}" >/dev/null 2>&1; then
    fail "Required binary '${name}' is missing from PATH."
  else
    info "$(${name} --version 2>&1 | head -n 1 || true)"
  fi
}

check_writable_dir() {
  local path="$1"
  mkdir -p "${path}" 2>/dev/null || fail "Cannot create directory ${path}."
  if [[ -d "${path}" && ! -w "${path}" ]]; then
    fail "Directory ${path} is not writable."
  fi
}

check_disk_space() {
  local path="$1"
  local minimum_gb="${MIN_CONVERSION_FREE_GB:-5}"
  local available_kb
  available_kb="$(df -Pk "${path}" | awk 'NR==2 {print $4}')"
  local available_gb=$((available_kb / 1024 / 1024))
  if (( available_gb < minimum_gb )); then
    warn "Only ${available_gb}GiB free at ${path}; MIN_CONVERSION_FREE_GB=${minimum_gb}GiB."
  else
    info "Disk space at ${path}: ${available_gb}GiB free."
  fi
}

check_embedded_kernel() {
  local embed="${EMBEDDED_KERNEL_ROOT:-/usr/lib/vm-migrator/kernels}"
  local vmlinuz="${SUPERMIN_KERNEL:-${embed}/vmlinuz}"
  if [[ ! -r "${vmlinuz}" ]]; then
    warn "Embedded kernel missing at ${vmlinuz} (supermin will fail)."
    return
  fi
  info "Embedded kernel: ${vmlinuz}"
  if [[ -f "${embed}/kernel-version" ]]; then
    local kver
    kver="$(tr -d '[:space:]' <"${embed}/kernel-version")"
    if [[ -d "${embed}/modules/${kver}" ]]; then
      info "Embedded modules: ${embed}/modules/${kver}"
    else
      warn "Embedded modules tree missing for kernel ${kver}."
    fi
  fi
}

check_guestfish() {
  if ! guestfish --version >/dev/null 2>&1; then
    warn "guestfish --version failed (check VDDK libstdc++ sanitization)."
    return
  fi
  info "guestfish responds to --version"
  if timeout 180 guestfish -N fs list-filesystems >/tmp/guestfish-smoke.log 2>&1; then
    info "guestfish appliance smoke test passed"
  else
    warn "guestfish appliance smoke test failed: $(tr '\n' ' ' </tmp/guestfish-smoke.log | cut -c1-400)"
  fi
}

check_vddk() {
  local libdir="${VMWARE_VDDK_LIBDIR:-/opt/vmware-vddk}"
  local plugin_dir="${VMWARE_VDDK_NBDKIT_PLUGIN_PATH:-/usr/lib/x86_64-linux-gnu/nbdkit/plugins}"

  if [[ "${VMWARE_ESXI_CONVERSION_TRANSPORT:-vddk}" != "vddk" ]]; then
    info "VDDK checks skipped (transport is not vddk)."
    return
  fi

  if [[ ! -d "${libdir}" ]]; then
    warn "VMWARE_VDDK_LIBDIR=${libdir} missing."
    return
  fi

  if find "${libdir}" -name 'libvixDiskLib.so*' -print -quit | grep -q .; then
    info "libvixDiskLib present under ${libdir}"
  else
    warn "libvixDiskLib.so not found under ${libdir}"
  fi

  if [[ -e "${libdir}/lib64/libstdc++.so.6" && ! -e "${libdir}/lib64/libstdc++.so.6.disabled" ]]; then
    warn "VDDK libstdc++.so.6 is still active — run vddk-sanitize-libcxx."
  fi

  if find "${plugin_dir}" -name '*vddk*.so' -print -quit | grep -q .; then
    info "nbdkit VDDK plugin present in ${plugin_dir}"
  else
    warn "nbdkit VDDK plugin not found in ${plugin_dir}"
  fi

  if virt-v2v --machine-readable 2>/tmp/virt-v2v-features.log | grep -qx vddk; then
    info "virt-v2v advertises vddk transport"
  else
    warn "virt-v2v does not list vddk in --machine-readable output"
  fi

  if nbdkit --dump-plugin vddk >/tmp/nbdkit-vddk.out 2>&1; then
    info "nbdkit VDDK plugin loads"
  else
    warn "nbdkit VDDK plugin: $(tr '\n' ' ' </tmp/nbdkit-vddk.out | cut -c1-300)"
  fi
}

check_openstack_connectivity() {
  if [[ -z "${OS_AUTH_URL:-}" ]]; then
    warn "OpenStack check skipped: OS_AUTH_URL unset."
    return
  fi
  if python - <<'PY' 2>/tmp/openstack-preflight.err
import os
import openstack
import sys

try:
    conn = openstack.connect(
        auth_url=os.environ["OS_AUTH_URL"],
        username=os.environ.get("OS_USERNAME"),
        password=os.environ.get("OS_PASSWORD"),
        project_name=os.environ.get("OS_PROJECT_NAME"),
        user_domain_name=os.environ.get("OS_USER_DOMAIN_NAME", "Default"),
        project_domain_name=os.environ.get("OS_PROJECT_DOMAIN_NAME", "Default"),
        region_name=os.environ.get("OS_REGION_NAME"),
        verify=os.environ.get("OS_VERIFY", "true").lower() not in {"0", "false", "no"},
    )
    conn.authorize()
except Exception as exc:
    print(f"{type(exc).__name__}: {exc}", file=sys.stderr)
    raise SystemExit(1)
PY
  then
    info "OpenStack authorization OK"
  else
    warn "OpenStack authorization failed (destination unreachable or bad credentials): $(tail -n 1 /tmp/openstack-preflight.err | cut -c1-220)"
  fi
}

check_vmware_connectivity() {
  local host="${VMWARE_ESXI_HOST:-${VMWARE_HOST:-}}"
  if [[ -z "${host}" ]]; then
    warn "VMware check skipped: VMWARE_ESXI_HOST unset."
    return
  fi
  if python - <<'PY' 2>/tmp/vmware-preflight.err
import os
import ssl
import sys
from pyVim.connect import Disconnect, SmartConnect

host = os.environ.get("VMWARE_ESXI_HOST") or os.environ.get("VMWARE_HOST")
user = os.environ.get("VMWARE_ESXI_USERNAME") or os.environ.get("VMWARE_USERNAME")
password = os.environ.get("VMWARE_ESXI_PASSWORD") or os.environ.get("VMWARE_PASSWORD")
port = int(os.environ.get("VMWARE_ESXI_PORT", "443"))
if not user or not password:
    print("missing credentials", file=sys.stderr)
    raise SystemExit(1)

context = None
if os.environ.get("VMWARE_ESXI_INSECURE", "false").lower() in {"1", "true", "yes"}:
    context = ssl._create_unverified_context()

try:
    si = SmartConnect(host=host, user=user, pwd=password, port=port, sslContext=context)
    Disconnect(si)
except Exception as exc:
    print(f"{type(exc).__name__}: {exc}", file=sys.stderr)
    raise SystemExit(1)
PY
  then
    info "VMware ESXi connection OK (${host})"
  else
    warn "VMware ESXi connection failed (${host}): $(tail -n 1 /tmp/vmware-preflight.err | cut -c1-220)"
  fi
}

info "Starting conversion worker preflight (strict=${strict})..."

require_env DATABASE_URL
require_env REDIS_URL
require_env MIGRATION_OUTPUT_DIR

require_bin virt-v2v
require_bin qemu-img
require_bin qemu-system-x86_64
require_bin guestfish
require_bin supermin
require_bin nbdkit
require_bin ansible-playbook

if [[ "${ENABLE_TERRAFORM_FROM_CELERY:-false}" =~ ^(1|true|yes)$ ]]; then
  require_bin terraform
fi

check_writable_dir "${MIGRATION_OUTPUT_DIR}"
check_writable_dir "${ARTIFACT_BACKUP_DIR:-${MIGRATION_OUTPUT_DIR}/backups}"
check_writable_dir /var/cache/guestfs
check_writable_dir "${TERRAFORM_PLUGIN_CACHE_DIR:-/opt/terraform/plugin-cache}"
check_disk_space "${MIGRATION_OUTPUT_DIR}"

check_embedded_kernel

if ! python - <<'PY'
import django
import os
from django.db import connection

os.environ.setdefault("DJANGO_SETTINGS_MODULE", "core.settings")
django.setup()
with connection.cursor() as cursor:
    cursor.execute("SELECT 1")
PY
then
  fail "MariaDB connectivity failed."
else
  info "MariaDB connectivity OK"
fi

if ! python - <<'PY'
import os
import redis

client = redis.Redis.from_url(os.environ["REDIS_URL"], socket_connect_timeout=5, socket_timeout=5)
client.ping()
PY
then
  fail "Redis connectivity failed."
else
  info "Redis connectivity OK"
fi

check_guestfish
check_vddk
check_openstack_connectivity
check_vmware_connectivity

if (( errors > 0 )); then
  echo "Preflight finished with ${errors} error(s) and ${warnings} warning(s)." >&2
  if [[ "${strict}" == "true" ]]; then
    exit 1
  fi
  exit 0
fi

echo "Preflight passed with ${warnings} warning(s)."
exit 0
