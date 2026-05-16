#!/usr/bin/env bash
set -Eeuo pipefail

errors=0
warnings=0

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
    warn "Only ${available_gb}GiB free at ${path}; MIN_CONVERSION_FREE_GB=${minimum_gb}GiB. Some conversions may fail."
  else
    info "Disk space at ${path}: ${available_gb}GiB free."
  fi
}

check_vddk() {
  local libdir="${VMWARE_VDDK_LIBDIR:-/opt/vmware-vddk}"
  local plugin_dir="${VMWARE_VDDK_NBDKIT_PLUGIN_PATH:-/usr/lib/x86_64-linux-gnu/nbdkit/plugins}"

  if [[ "${VMWARE_ESXI_CONVERSION_TRANSPORT:-vddk}" != "vddk" ]]; then
    info "VDDK checks skipped because VMWARE_ESXI_CONVERSION_TRANSPORT is not vddk."
    return
  fi

  if [[ ! -d "${libdir}" ]]; then
    warn "VMWARE_VDDK_LIBDIR=${libdir} does not exist. VDDK transport will fail; use nbdkit or HTTP transport instead."
    return
  fi

  if ! find "${libdir}" -name 'libvixDiskLib.so*' -print -quit | grep -q .; then
    warn "No libvixDiskLib.so found under ${libdir}. VDDK transport unavailable."
  fi

  if [[ ! -d "${plugin_dir}" ]]; then
    warn "VMWARE_VDDK_NBDKIT_PLUGIN_PATH=${plugin_dir} does not exist."
  elif ! find "${plugin_dir}" -name '*vddk*.so' -print -quit | grep -q .; then
    warn "nbdkit VDDK plugin was not found in ${plugin_dir}. VDDK transport unavailable."
  fi

  # Test nbdkit VDDK plugin with proper LD environment
  if ! LD_LIBRARY_PATH="${VMWARE_VDDK_LIBDIR}/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
       LD_PRELOAD="/usr/lib/x86_64-linux-gnu/libstdc++.so.6:/lib/x86_64-linux-gnu/libgcc_s.so.1${LD_PRELOAD:+:$LD_PRELOAD}" \
       nbdkit --dump-plugin vddk >/tmp/nbdkit-vddk.out 2>&1; then
    warn "nbdkit cannot load the VDDK plugin: $(tr '\n' ' ' </tmp/nbdkit-vddk.out | cut -c1-300)"
  fi
}

check_openstack_connectivity() {
  if [[ -z "${OS_AUTH_URL:-}" ]]; then
    warn "OpenStack connectivity check skipped: OS_AUTH_URL is not set."
    return
  fi

  python - <<'PY'
import os
import sys
import openstack

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
    print(f"OpenStack authorization failed: {exc}", file=sys.stderr)
    sys.exit(1)
PY
}

check_vmware_connectivity() {
  local host="${VMWARE_ESXI_HOST:-${VMWARE_HOST:-}}"
  if [[ -z "${host}" ]]; then
    warn "VMware connectivity check skipped: VMWARE_ESXI_HOST/VMWARE_HOST is not set."
    return
  fi

  python - <<'PY'
import os
import ssl
import sys
from pyVim.connect import Disconnect, SmartConnect

host = os.environ.get("VMWARE_ESXI_HOST") or os.environ.get("VMWARE_HOST")
user = os.environ.get("VMWARE_ESXI_USERNAME") or os.environ.get("VMWARE_USERNAME")
password = os.environ.get("VMWARE_ESXI_PASSWORD") or os.environ.get("VMWARE_PASSWORD")
port = int(os.environ.get("VMWARE_ESXI_PORT", "443"))
if not user or not password:
    print("VMware host was supplied but username/password are missing.", file=sys.stderr)
    sys.exit(1)

context = None
if os.environ.get("VMWARE_ESXI_INSECURE", "false").lower() in {"1", "true", "yes"}:
    context = ssl._create_unverified_context()

try:
    si = SmartConnect(host=host, user=user, pwd=password, port=port, sslContext=context)
    Disconnect(si)
except Exception as exc:
    print(f"VMware connection failed: {exc}", file=sys.stderr)
    sys.exit(1)
PY
}

info "Starting conversion worker preflight validation..."

require_env DATABASE_URL
require_env REDIS_URL
require_env MIGRATION_OUTPUT_DIR

require_bin virt-v2v
require_bin qemu-img
require_bin guestfish
require_bin virt-filesystems
require_bin nbdkit
require_bin ansible-playbook
require_bin ssh

if [[ "${ENABLE_TERRAFORM_FROM_CELERY:-false}" =~ ^(1|true|yes)$ ]]; then
  require_bin terraform
fi

check_writable_dir "${MIGRATION_OUTPUT_DIR}"
check_writable_dir "${ARTIFACT_BACKUP_DIR:-${MIGRATION_OUTPUT_DIR}/backups}"
check_writable_dir /var/cache/guestfs
check_writable_dir "${TERRAFORM_PLUGIN_CACHE_DIR:-/opt/terraform/plugin-cache}"
check_disk_space "${MIGRATION_OUTPUT_DIR}"

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
  fail "Django database connectivity failed."
fi

if ! python - <<'PY'
import os
import redis

url = os.environ.get("REDIS_URL")
client = redis.Redis.from_url(url, socket_connect_timeout=3, socket_timeout=3)
client.ping()
PY
then
  fail "Redis broker connectivity failed."
fi

if ! guestfish --version >/dev/null 2>&1; then
  fail "libguestfs userland is installed but guestfish cannot start."
fi

check_vddk

if [[ "${REQUIRE_PREFLIGHT_CONNECTIVITY:-false}" == "true" ]]; then
  check_openstack_connectivity || fail "OpenStack connectivity validation failed."
  check_vmware_connectivity || fail "VMware connectivity validation failed."
else
  check_openstack_connectivity || warn "OpenStack connectivity validation failed."
  check_vmware_connectivity || warn "VMware connectivity validation failed."
fi

if (( errors > 0 )); then
  echo "Conversion worker preflight failed with ${errors} error(s) and ${warnings} warning(s)." >&2
  exit 1
fi

echo "Conversion worker preflight passed with ${warnings} warning(s)."
