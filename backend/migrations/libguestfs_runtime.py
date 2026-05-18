"""Libguestfs / virt-v2v runtime helpers for TCG-safe Docker conversions."""

from __future__ import annotations

import os
from pathlib import Path
from typing import Any

from django.conf import settings


def migration_job_log_dir(job_id: int, *, base: Path | None = None) -> Path:
    root = base or Path(getattr(settings, "MIGRATION_OUTPUT_DIR", "/var/lib/vm-migrator/images"))
    log_dir = root / "tmp" / f"job-{job_id}" / "logs"
    log_dir.mkdir(parents=True, exist_ok=True)
    return log_dir


def build_libguestfs_runtime_env(base_env: dict[str, str] | None = None) -> dict[str, str]:
    """Return env vars that force direct backend, TCG, and a single-CPU appliance."""
    env = dict(base_env or os.environ)

    env["LIBGUESTFS_BACKEND"] = str(getattr(settings, "LIBGUESTFS_BACKEND", "direct"))
    env["LIBGUESTFS_BACKEND_SETTINGS"] = str(
        getattr(settings, "LIBGUESTFS_BACKEND_SETTINGS", "force_tcg")
    )
    env["LIBGUESTFS_MEMSIZE"] = str(int(getattr(settings, "LIBGUESTFS_MEMSIZE", 768)))
    cpus = str(int(getattr(settings, "LIBGUESTFS_CPUS", 1)))
    env["LIBGUESTFS_CPUS"] = cpus
    # Older libguestfs builds honor LIBGUESTFS_SMP for appliance -smp.
    env["LIBGUESTFS_SMP"] = cpus

    threads = int(getattr(settings, "VIRT_V2V_NBDKIT_THREADS", 1))
    env["VIRT_V2V_NBDKIT_THREADS"] = str(threads)

    supermin_kernel = str(getattr(settings, "SUPERMIN_KERNEL", "")).strip()
    if supermin_kernel:
        env["SUPERMIN_KERNEL"] = supermin_kernel

    embed_root = str(getattr(settings, "EMBEDDED_KERNEL_ROOT", "")).strip()
    if embed_root:
        env["EMBEDDED_KERNEL_ROOT"] = embed_root

    tools_conf = str(getattr(settings, "LIBGUESTFS_TOOLS_CONF", "/etc/libguestfs-tools.conf"))
    if tools_conf:
        env.setdefault("LIBGUESTFS_TOOLS_CONF", tools_conf)

    hv = str(getattr(settings, "LIBGUESTFS_HV", "")).strip()
    if hv:
        env["LIBGUESTFS_HV"] = hv

    return env


def libguestfs_ansible_extra_vars() -> dict[str, Any]:
    """Flatten libguestfs settings for Ansible extra-vars."""
    env = build_libguestfs_runtime_env({})
    return {
        "libguestfs_backend": env["LIBGUESTFS_BACKEND"],
        "libguestfs_backend_settings": env["LIBGUESTFS_BACKEND_SETTINGS"],
        "libguestfs_memsize": env["LIBGUESTFS_MEMSIZE"],
        "libguestfs_cpus": env["LIBGUESTFS_CPUS"],
        "virt_v2v_nbdkit_threads": env["VIRT_V2V_NBDKIT_THREADS"],
        "virt_v2v_debug": os.getenv("VIRT_V2V_DEBUG", "").lower() in {"1", "true", "yes"},
    }


def persist_execution_logs(
    job_id: int | None,
    label: str,
    stdout: str,
    stderr: str,
    *,
    log_dir: Path | None = None,
) -> dict[str, str]:
    if job_id is None:
        return {}

    target = log_dir or migration_job_log_dir(job_id)
    app_log_root = Path(getattr(settings, "LOG_DIR", "/app/logs"))
    app_log_root.mkdir(parents=True, exist_ok=True)

    paths: dict[str, str] = {}
    for stream, content in (("stdout", stdout or ""), ("stderr", stderr or "")):
        job_path = target / f"{label}.{stream}.log"
        job_path.write_text(content, encoding="utf-8", errors="replace")
        paths[f"job_{stream}"] = str(job_path)

        app_path = app_log_root / f"job-{job_id}-{label}.{stream}.log"
        app_path.write_text(content, encoding="utf-8", errors="replace")
        paths[f"app_{stream}"] = str(app_path)

    return paths
