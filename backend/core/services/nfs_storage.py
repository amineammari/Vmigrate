import os
from django.conf import settings

from .storage import storage_manager


def check_nfs_mounted():
    """Raise if NFS is not available according to storage manager.

    This centralizes the validation logic so callers don't rely on hardcoded
    settings values.
    """
    if not storage_manager._nfs_available():
        raise Exception(f"NFS not available at {settings.NFS_PATH}")


def prepare_vm_dirs(vm_id):
    vmdk_path = storage_manager.nfs_base / str(vm_id) / "vmdk"
    qcow2_path = storage_manager.nfs_base / str(vm_id) / "qcow2"
    os.makedirs(vmdk_path, exist_ok=True)
    os.makedirs(qcow2_path, exist_ok=True)
    return str(vmdk_path), str(qcow2_path)
