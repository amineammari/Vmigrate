"""Host-based execution for conversion tools via SSH.

This module provides secure execution of heavy system tools (virt-v2v, qemu-img, etc.)
on a remote host via SSH, keeping Docker containers lightweight.

Usage:
    from migrations.host_executor import execute_on_host
    result = execute_on_host(["virt-v2v", ...], timeout=7200)
"""

from __future__ import annotations

import json
import logging
import os
import subprocess
import tempfile
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import django

logger = logging.getLogger(__name__)


class HostExecutionError(Exception):
    """Raised when host execution fails."""

    def __init__(self, message: str, returncode: int = -1, stdout: str = "", stderr: str = "") -> None:
        super().__init__(message)
        self.returncode = returncode
        self.stdout = stdout
        self.stderr = stderr


@dataclass
class HostExecutionResult:
    """Result of host-based execution."""

    success: bool
    returncode: int
    stdout: str
    stderr: str
    command: list[str] = field(default_factory=list)
    duration_seconds: float = 0.0


def _get_ssh_config() -> dict[str, Any]:
    """Get SSH configuration from Django settings."""
    from django.conf import settings

    return {
        "host": getattr(settings, "CONVERSION_HOST", "localhost"),
        "user": getattr(settings, "CONVERSION_USER", os.environ.get("USER", "root")),
        "key_file": getattr(settings, "CONVERSION_SSH_KEY", None),
        "port": getattr(settings, "CONVERSION_SSH_PORT", 22),
    }


def _build_ssh_command(
    remote_command: list[str],
    *,
    host: str = "localhost",
    user: str = "root",
    key_file: str | None = None,
    port: int = 22,
) -> list[str]:
    """Build SSH command for remote execution."""
    cmd = ["ssh", "-o", "StrictHostKeyChecking=no"]

    if key_file:
        cmd.extend(["-i", key_file])

    if port != 22:
        cmd.extend(["-p", str(port)])

    # Build connection string
    connection = f"{user}@{host}" if user != "root" else host
    cmd.append(connection)

    # Add remote command (quoted for proper shell handling)
    remote_cmd = " ".join(remote_command)
    if any(c in remote_cmd for c in ["&", "||", "&&", ";", "$(", "`"]):
        cmd.append(remote_cmd)
    else:
        # Simple command - pass as-is for efficiency
        cmd.extend(remote_command)

    return cmd


def execute_on_host(
    command: list[str],
    *,
    timeout: int = 7200,
    cwd: str | None = None,
    env: dict[str, str] | None = None,
    capture_output: bool = True,
) -> HostExecutionResult:
    """Execute a command on the conversion host via SSH.

    Args:
        command: Command and arguments to execute
        timeout: Timeout in seconds
        cwd: Working directory on remote host
        env: Environment variables
        capture_output: Whether to capture stdout/stderr

    Returns:
        HostExecutionResult with execution details

    Raises:
        HostExecutionError: If execution fails
    """
    import time

    ssh_config = _get_ssh_config()
    host = ssh_config["host"]
    user = ssh_config["user"]
    key_file = ssh_config["key_file"]
    port = ssh_config["port"]

    # Build SSH command
    ssh_cmd = _build_ssh_command(
        command,
        host=host,
        user=user,
        key_file=key_file,
        port=port,
    )

    from .libguestfs_runtime import build_libguestfs_runtime_env

    # Prepare environment - filter out variables that should not be passed to host
    run_env = build_libguestfs_runtime_env(os.environ.copy())
    # Remove variables that may cause issues on host (paths/installation-specific)
    for var in ["SUPERMIN_KERNEL", "LIBGUESTFS_CACHEDIR", "LIBGUESTFS_HV", "LIBGUESTFS_MOUNT_OPTIONS"]:
        run_env.pop(var, None)
    if env:
        run_env.update(env)

    if cwd:
        # Prepend cd to command
        ssh_cmd[-1] = f"cd {cwd} && {ssh_cmd[-1]}"

    logger.info(
        "host_execution.start",
        extra={
            "host": host,
            "command": command[0],
            "timeout": timeout,
        },
    )

    start_time = time.monotonic()

    try:
        completed = subprocess.run(
            ssh_cmd,
            capture_output=capture_output,
            text=True,
            check=False,
            timeout=timeout,
            env=run_env,
        )
    except subprocess.TimeoutExpired as exc:
        raise HostExecutionError(
            f"Command timed out after {timeout}s",
            returncode=-1,
            stdout=exc.stdout.decode() if exc.stdout else "",
            stderr=exc.stderr.decode() if exc.stderr else "",
        ) from exc
    except FileNotFoundError as exc:
        raise HostExecutionError(
            f"SSH not found. Is OpenSSH installed?",
            returncode=-1,
        ) from exc
    except OSError as exc:
        raise HostExecutionError(
            f"Failed to execute SSH: {exc}",
            returncode=-1,
        ) from exc

    duration = round(time.monotonic() - start_time, 3)
    success = completed.returncode == 0

    logger.info(
        "host_execution.finished",
        extra={
            "host": host,
            "returncode": completed.returncode,
            "duration_seconds": duration,
            "success": success,
        },
    )

    return HostExecutionResult(
        success=success,
        returncode=completed.returncode,
        stdout=completed.stdout or "",
        stderr=completed.stderr or "",
        command=command,
        duration_seconds=duration,
    )


def execute_virt_v2v(
    command_args: list[str],
    *,
    output_dir: str,
    timeout: int = 7200,
    ssh_config: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """Execute virt-v2v on remote host with proper error handling.

    Args:
        command_args: virt-v2v arguments (without 'virt-v2v' prefix)
        output_dir: Output directory for conversion
        timeout: Timeout in seconds
        ssh_config: Override SSH config

    Returns:
        Dict with execution result
    """
    command = ["virt-v2v", *command_args]

    result = execute_on_host(
        command,
        timeout=timeout,
        cwd=output_dir,
    )

    return {
        "success": result.success,
        "returncode": result.returncode,
        "stdout": result.stdout,
        "stderr": result.stderr,
        "duration_seconds": result.duration_seconds,
    }


def execute_qemu_img(
    args: list[str],
    timeout: int = 300,
) -> HostExecutionResult:
    """Execute qemu-img on remote host."""
    command = ["qemu-img", *args]
    return execute_on_host(command, timeout=timeout)


def test_host_connection() -> dict[str, Any]:
    """Test SSH connectivity to conversion host.

    Returns:
        Dict with connection status and details
    """
    ssh_config = _get_ssh_config()
    host = ssh_config["host"]

    result = execute_on_host(
        ["echo", "connection_test"],
        timeout=30,
    )

    return {
        "success": result.success,
        "host": host,
        "returncode": result.returncode,
        "stdout": result.stdout.strip(),
        "stderr": result.stderr,
    }