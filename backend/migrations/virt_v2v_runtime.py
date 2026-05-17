"""virt-v2v version detection and transport option compatibility."""

from __future__ import annotations

import re
import shutil
import subprocess
from functools import lru_cache

# virt-v2v 2.2.x rejects `-io vddk-threads`; support starts at 2.3.0.
VDDK_THREADS_MIN_VERSION = (2, 3, 0)


def parse_virt_v2v_version(text: str) -> tuple[int, int, int] | None:
    """Parse a virt-v2v version string such as 'virt-v2v 2.2.0'."""
    if not text:
        return None
    match = re.search(r"virt-v2v\s+v?(\d+)\.(\d+)\.(\d+)", text, flags=re.IGNORECASE)
    if not match:
        match = re.search(r"\b(\d+)\.(\d+)\.(\d+)\b", text)
    if not match:
        return None
    return int(match.group(1)), int(match.group(2)), int(match.group(3))


@lru_cache(maxsize=1)
def get_virt_v2v_version() -> tuple[int, int, int] | None:
    """Return the installed virt-v2v version by running `virt-v2v --version`."""
    binary = shutil.which("virt-v2v")
    if not binary:
        return None
    try:
        completed = subprocess.run(
            [binary, "--version"],
            capture_output=True,
            text=True,
            check=False,
            timeout=15,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    combined = f"{completed.stdout or ''}\n{completed.stderr or ''}"
    return parse_virt_v2v_version(combined)


def virt_v2v_supports_vddk_threads(version: tuple[int, int, int] | None = None) -> bool:
    """True when `-io vddk-threads=N` is accepted by the installed virt-v2v."""
    resolved = version if version is not None else get_virt_v2v_version()
    if resolved is None:
        # Unknown version: do not inject options that break 2.2.x.
        return False
    return resolved >= VDDK_THREADS_MIN_VERSION


def format_virt_v2v_version(version: tuple[int, int, int] | None = None) -> str:
    resolved = version if version is not None else get_virt_v2v_version()
    if resolved is None:
        return "unknown"
    return ".".join(str(part) for part in resolved)


def build_vddk_transport_args(
    *,
    vddk_libdir: str,
    vddk_thumbprint: str,
    threads: int = 1,
    version: tuple[int, int, int] | None = None,
) -> tuple[list[str], list[str]]:
    """Build `-it vddk` and related `-io` flags; omit vddk-threads on older virt-v2v."""
    command_args = [
        "-it",
        "vddk",
        "-io",
        f"vddk-libdir={vddk_libdir}",
        "-io",
        f"vddk-thumbprint={vddk_thumbprint}",
    ]
    notes: list[str] = [
        "esxi conversion via VDDK (requires nbdkit-vddk-plugin; VM powered off)",
        f"virt-v2v {format_virt_v2v_version(version)}",
    ]
    if virt_v2v_supports_vddk_threads(version):
        thread_count = max(1, int(threads))
        command_args += ["-io", f"vddk-threads={thread_count}"]
        notes.append(f"vddk-threads={thread_count} (virt-v2v >= 2.3)")
    else:
        notes.append("vddk-threads omitted (not supported by virt-v2v < 2.3)")
    return command_args, notes
