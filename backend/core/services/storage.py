import errno
import logging
import os
from pathlib import Path
from typing import Optional

from django.conf import settings

logger = logging.getLogger("core.storage")


class StorageManager:
    """Storage abstraction that chooses between local and NFS-backed storage.

    Use `use_nfs` parameter to override per-operation (e.g. controlled by checkbox).
    Otherwise, the global `settings.NFS_ENABLED` is used.
    """

    def __init__(self):
        # Local base path is the existing output dir used by the app
        self.local_base = Path(settings.MIGRATION_OUTPUT_DIR)
        self.nfs_base = Path(settings.NFS_PATH)
        self.nfs_enabled = bool(getattr(settings, "NFS_ENABLED", False))
        self.nfs_validate = bool(getattr(settings, "NFS_VALIDATE_MOUNT", True))

    def _nfs_available(self) -> bool:
        try:
            if self.nfs_validate:
                # prefer ismount but some container setups mount via bind, so
                # fall back to existence + readability check
                if os.path.ismount(str(self.nfs_base)):
                    return True
            # fallback: check directory is present and we can list it
            return os.access(str(self.nfs_base), os.R_OK | os.W_OK | os.X_OK)
        except Exception:
            logger.exception("Error while validating NFS path %s", self.nfs_base)
            return False

    def should_use_nfs(self, use_nfs: Optional[bool] = None) -> bool:
        """Decide whether to use NFS for an operation.

        Priority: explicit `use_nfs` argument -> global `NFS_ENABLED` + mount validation.
        An explicit `use_nfs=True` can enable NFS even when `NFS_ENABLED` is false;
        the global setting only controls the default when no override is supplied.
        """
        if use_nfs is not None:
            if use_nfs:
                return self._nfs_available()
            return False
        return self.nfs_enabled and self._nfs_available()

    def base_path(self, use_nfs: Optional[bool] = None) -> Path:
        if self.should_use_nfs(use_nfs):
            logger.debug("Using NFS storage at %s", self.nfs_base)
            return self.nfs_base
        logger.debug("Using local storage at %s", self.local_base)
        return self.local_base

    def path_for(self, filename: str, subdir: Optional[str] = None, use_nfs: Optional[bool] = None) -> Path:
        base = self.base_path(use_nfs)
        if subdir:
            base = base / subdir
        return base / filename

    def ensure_dir(self, path: Path, mode: int = 0o755) -> None:
        try:
            path.mkdir(parents=True, exist_ok=True)
        except OSError as e:
            if e.errno != errno.EEXIST:
                raise

    def save_bytes(self, data: bytes, filename: str, subdir: Optional[str] = None, use_nfs: Optional[bool] = None) -> Path:
        p = self.path_for(filename, subdir=subdir, use_nfs=use_nfs)
        self.ensure_dir(p.parent)
        with open(p, "wb") as f:
            f.write(data)
        logger.info("Saved file %s (storage=%s)", p, "nfs" if self.should_use_nfs(use_nfs) else "local")
        return p

    def open(self, filename: str, mode: str = "rb", subdir: Optional[str] = None, use_nfs: Optional[bool] = None):
        p = self.path_for(filename, subdir=subdir, use_nfs=use_nfs)
        return open(p, mode)

    def exists(self, filename: str, subdir: Optional[str] = None, use_nfs: Optional[bool] = None) -> bool:
        p = self.path_for(filename, subdir=subdir, use_nfs=use_nfs)
        return p.exists()


# Module-level instance for convenience. Import and call functions/storage_manager.should_use_nfs(...)
storage_manager = StorageManager()
