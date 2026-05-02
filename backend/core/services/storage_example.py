"""Small examples showing how to use `storage_manager` for conversions and uploads.

Replace any direct writes to `settings.MIGRATION_OUTPUT_DIR` or hardcoded paths
with the helpers below. Background workers should import the same helper so both
API and worker containers behave consistently.
"""
from pathlib import Path
import shutil
import logging

from core.services.storage import storage_manager

logger = logging.getLogger("core.storage.example")


def move_conversion_output(tmp_file_path: str, final_filename: str, use_nfs: bool | None = None, subdir: str | None = None) -> Path:
    """Move a temp conversion output into persistent storage.

    - `tmp_file_path` is the temporary path created by qemu-img/virt-v2v
    - `final_filename` is the desired final filename (e.g. vm-name.qcow2)
    - `use_nfs` overrides the checkbox setting (None -> use global setting)
    - `subdir` optionally groups images under a subfolder
    """
    dest_path = storage_manager.path_for(final_filename, subdir=subdir, use_nfs=use_nfs)
    storage_manager.ensure_dir(dest_path.parent)
    shutil.move(tmp_file_path, dest_path)
    logger.info("Moved conversion output to %s (storage=%s)", dest_path, "nfs" if storage_manager.should_use_nfs(use_nfs) else "local")
    return dest_path


def save_uploaded_stream(stream, filename: str, use_nfs: bool | None = None, subdir: str | None = None) -> Path:
    """Save a file-like stream into storage (used by upload handlers).
    Stream must support .read()."""
    data = stream.read()
    return storage_manager.save_bytes(data, filename, subdir=subdir, use_nfs=use_nfs)
