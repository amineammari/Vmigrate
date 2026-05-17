"""Safe conversion planning for virt-v2v workflows."""

from __future__ import annotations

import os
import re
import shlex
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from .models import DiscoveredVM
from .virt_v2v_runtime import build_vddk_transport_args
from core.services.storage import storage_manager


class ConversionPlanningError(Exception):
    """Raised when conversion planning cannot be generated safely."""


@dataclass
class ConversionPlan:
    command: str
    command_args: list[str]
    input_disks: list[str]
    output_path: str
    notes: list[str] = field(default_factory=list)


def _sanitize_name(value: str) -> str:
    clean = re.sub(r"[^A-Za-z0-9._-]", "-", value).strip("-._")
    return clean or "vm"


def _extract_disk_paths(disks: Any) -> list[str]:
    if not isinstance(disks, list):
        return []

    paths: list[str] = []
    for disk in disks:
        if isinstance(disk, dict):
            path = disk.get("path")
            if isinstance(path, str) and path.strip():
                paths.append(path.strip())
        elif isinstance(disk, str) and disk.strip():
            paths.append(disk.strip())

    seen = set()
    deduped: list[str] = []
    for path in paths:
        if path not in seen:
            deduped.append(path)
            seen.add(path)
    return deduped


def _build_command(args: list[str]) -> str:
    return " ".join(shlex.quote(part) for part in args)


def plan_vmware_conversion(
    discovered_vm: DiscoveredVM,
    output_dir: str | None = None,
    use_nfs: bool | None = None,
    *,
    esxi_uri: str | None = None,
    password_file: str | None = None,
    esxi_transport: str | None = None,
    vddk_libdir: str | None = None,
    vddk_thumbprint: str | None = None,
) -> ConversionPlan:
    """Build a virt-v2v command plan from discovered VM data."""

    # Determine a base output directory via storage manager (local vs NFS)
    if output_dir:
        output_dir = Path(output_dir).expanduser()
    else:
        output_dir = storage_manager.base_path(use_nfs)
    output_path = str(Path(output_dir) / f"{_sanitize_name(discovered_vm.name)}.qcow2")

    if discovered_vm.source == DiscoveredVM.Source.WORKSTATION:
        input_disks = _extract_disk_paths(discovered_vm.disks)
        if not input_disks:
            raise ConversionPlanningError(
                f"No local VMDK paths available for workstation VM '{discovered_vm.name}'."
            )

        command_args: list[str]
        notes: list[str] = []
        vmx_path = None
        if isinstance(discovered_vm.metadata, dict):
            vmx_path = discovered_vm.metadata.get("vmx_path") or discovered_vm.metadata.get("vmx_datastore_path")

        # Prefer VMX import for full VM conversion (handles multi-disk VMs).
        if isinstance(vmx_path, str) and vmx_path.strip():
            vmx = Path(vmx_path).expanduser()
            if vmx.exists() and vmx.is_file():
                command_args = [
                    "virt-v2v",
                    "-i",
                    "vmx",
                    str(vmx),
                    "-o",
                    "local",
                    "-os",
                    str(output_dir),
                    "-of",
                    "qcow2",
                    "-on",
                    discovered_vm.name,
                ]
                if len(input_disks) > 1:
                    notes.append("multi-disk VM detected; conversion uses VMX import to preserve all disks")
            else:
                notes.append(
                    f"vmx_path not found ({vmx}); using qemu-img per-disk workflow to keep 1-to-1 disk architecture"
                )
                command_args = [
                    "qemu-img",
                    "convert",
                    "-f",
                    "<detected>",
                    "-O",
                    "qcow2",
                    "<source-disk>",
                    "<target-disk>",
                ]
        else:
            notes.append("vmx_path unavailable; using qemu-img per-disk workflow (1-to-1, same order, no merge)")
            command_args = [
                "qemu-img",
                "convert",
                "-f",
                "<detected>",
                "-O",
                "qcow2",
                "<source-disk>",
                "<target-disk>",
            ]

        return ConversionPlan(
            command=_build_command(command_args),
            command_args=command_args,
            input_disks=input_disks,
            output_path=output_path,
            notes=notes,
        )

    if discovered_vm.source == DiscoveredVM.Source.ESXI:
        # ESXi conversion: use libvirt ESX driver over HTTPS with VDDK for disk access
        if not esxi_uri:
            raise ConversionPlanningError("Missing esxi_uri for ESXi conversion planning.")
        
        # Validate VM name for libvirt compatibility (alphanumeric, dots, dashes, underscores only)
        vm_guest_name = discovered_vm.name
        if not re.match(r'^[a-zA-Z0-9._-]+$', vm_guest_name):
            # If VM name has invalid characters, use a sanitized version as the domain name
            vm_guest_name = re.sub(r'[^a-zA-Z0-9._-]', '-', vm_guest_name).strip('-')
            if not vm_guest_name:
                vm_guest_name = "vm"

        command_args = ["virt-v2v", "-i", "libvirt", "-ic", esxi_uri]
        if password_file:
            command_args += ["-ip", password_file]

        notes = ["esxi conversion via libvirt esx:// (requires VM powered off for safety)"]
        if esxi_transport == "vddk":
            if not vddk_libdir or not vddk_thumbprint:
                raise ConversionPlanningError("VDDK transport requires vddk_libdir and vddk_thumbprint.")
            nbdkit_threads = int(os.getenv("VIRT_V2V_NBDKIT_THREADS", "1") or "1")
            vddk_args, notes = build_vddk_transport_args(
                vddk_libdir=vddk_libdir,
                vddk_thumbprint=vddk_thumbprint,
                threads=nbdkit_threads,
            )
            command_args += vddk_args

        command_args += [
            vm_guest_name,
            "-o",
            "local",
            "-os",
            str(output_dir),
            "-of",
            "qcow2",
            "-on",
            _sanitize_name(discovered_vm.name),
        ]
        return ConversionPlan(
            command=_build_command(command_args),
            command_args=command_args,
            input_disks=[],
            output_path=output_path,
            notes=notes,
        )

    raise ConversionPlanningError(
        f"Unsupported VMware source '{discovered_vm.source}' for VM '{discovered_vm.name}'."
    )
