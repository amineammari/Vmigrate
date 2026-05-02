# virt-v2v ESXi Conversion - Fix Guide

## Problem Summary
When attempting ESXi VM conversions, the system was failing with:
```
virt-v2v: error: -i libvirt: expecting a libvirt guest name on the command line
```

The conversion plan was being generated but execution failed because critical tools were missing from the Docker worker container.

---

## Root Causes Identified

### 1. **Missing Docker Dependencies (Critical)**
The worker Docker image was not installing the required virt-v2v toolchain:
- ❌ `virt-v2v` - the main conversion tool
- ❌ `libvirt-clients` - required for libvirt URI connections (esx://)
- ❌ `nbdkit` + `nbdkit-plugin-vddk` - required for VDDK transport to access ESXi VM disks
- ❌ `qemu-utils` - required for disk format handling
- ❌ `libguestfs-tools` - required for guest filesystem inspection
- ❌ `ansible` - for playbook-based conversions (optional but documented)

**DOCKER_SETUP.md** documented these correctly, but the **Dockerfile** wasn't implementing them.

### 2. **VM Name Compatibility**
When using `-i libvirt -ic esx://`, virt-v2v interprets the VM name as a libvirt domain name, which has strict character restrictions (alphanumeric, dots, dashes, underscores only). VM names with spaces or special characters would fail.

### 3. **Libvirt Access**
With `network_mode: host`, the worker needs direct socket access to:
- `/var/run/libvirt/libvirt-sock` - the libvirt socket
- `/etc/libvirt/` - libvirt configuration

Without these, the esx:// connection cannot be established.

---

## Fixes Applied

### ✅ Fix 1: Updated Dockerfile Worker Stage
Lines 37-72 now include:
```dockerfile
FROM base AS worker

# Install conversion tools, libvirt, and infrastructure tools  
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        openssh-client \
        unzip \
        virt-v2v \
        libvirt-clients \
        qemu-utils \
        libguestfs-tools \
        libguestfs-xfs \
        libguestfs-reiserfs \
        nbdkit \
        nbdkit-plugin-vddk \
        libxml2 \
        libaugeas0 \
        && rm -rf /var/lib/apt/lists/*

# Install Ansible for playbook-based conversions
RUN pip install --no-cache-dir ansible

WORKDIR /app
COPY backend /app

# Create necessary directories for virt-v2v cache
RUN mkdir -p /var/cache/guestfs && \
    chmod 777 /var/cache/guestfs
```

### ✅ Fix 2: Improved ESXi Conversion Planning
**File**: `backend/migrations/conversion.py` (lines 138-182)

Now includes:
- VM name validation for libvirt compatibility
- Automatic sanitization of invalid characters
- Better separation of guest name vs output filename

```python
# Validate VM name for libvirt compatibility (alphanumeric, dots, dashes, underscores only)
vm_guest_name = discovered_vm.name
if not re.match(r'^[a-zA-Z0-9._-]+$', vm_guest_name):
    # If VM name has invalid characters, use a sanitized version as the domain name
    vm_guest_name = re.sub(r'[^a-zA-Z0-9._-]', '-', vm_guest_name).strip('-')
```

### ✅ Fix 3: Added Libvirt Socket Access
**File**: `docker-compose.yml` (worker service)

Added volumes:
```yaml
volumes:
  - /var/run/libvirt:/var/run/libvirt:ro
  - /etc/libvirt:/etc/libvirt:ro
```

---

## Steps to Apply Fixes

### 1. Rebuild Docker Images
```bash
cd /home/amin/Desktop/vm-migrator

# Full rebuild with no caching
docker-compose build --no-cache worker

# Or rebuild all services
docker-compose build --no-cache
```

### 2. Verify Libvirt is Running on Host
```bash
# Check if libvirt daemon is running
systemctl status libvirtd

# If not running, start it
sudo systemctl start libvirtd
sudo systemctl enable libvirtd

# Test libvirt is accessible
virsh uri
# Should output something like: qemu:///system
```

### 3. Restart Services
```bash
# Stop existing containers
docker-compose down

# Start fresh with rebuilt images
docker-compose up -d

# Verify worker is running
docker ps | grep vmigrate-worker
```

### 4. Verify Installation in Container
```bash
# Check virt-v2v is installed
docker exec vmigrate-worker which virt-v2v
# Should output: /usr/bin/virt-v2v

# Check libvirt-clients
docker exec vmigrate-worker which virsh
# Should output: /usr/bin/virsh

# Check nbdkit
docker exec vmigrate-worker which nbdkit
# Should output: /usr/bin/nbdkit
```

---

## Testing the Fix

### Test 1: Verify Docker Environment
```bash
docker exec vmigrate-worker bash -c 'virt-v2v --version'
```
**Expected output**: 
```
virt-v2v 1.x.x (libguestfs 1.x.x)
```

### Test 2: Check Libvirt Connection (if daemon accessible)
```bash
docker exec vmigrate-worker bash -c 'virsh -c qemu:///system list'
```
**Expected output**: List of VMs or connection successful message

### Test 3: Run Conversion Job
1. Navigate to the UI (http://localhost)
2. Create a Migration Job
3. Select an ESXi VM
4. Check the Conversion Plan
5. Monitor the execution in: `docker logs -f vmigrate-worker`

### Test 4: Monitor Logs
```bash
# Watch conversion in progress
docker logs -f vmigrate-worker

# Or check stored logs
tail -f ./backend/logs/celery.log
tail -f ./backend/logs/worker.log
```

---

## If Issues Persist

### Issue: "virt-v2v: error: -i libvirt: expecting a libvirt guest name"

**Diagnosis**:
1. Verify virt-v2v is installed:
   ```bash
   docker exec vmigrate-worker which virt-v2v
   ```

2. Check the conversion plan being sent:
   - Look in `MigrationJob` metadata → `conversion` → `plan` → `command`
   - Verify guest name is alphanumeric (no spaces or special chars)

3. Ensure ESXi host is reachable:
   ```bash
   docker exec vmigrate-worker ping 192.168.72.242
   docker exec vmigrate-worker curl -k https://192.168.72.242/
   ```

4. Verify credentials:
   - Check `.env` file has correct `VMWARE_ESXI_*` settings
   - Or verify the endpoint session has correct host/username/password

### Issue: "libvirt: error: permissiondenied"

**Diagnosis**:
1. Check libvirt socket permissions on host:
   ```bash
   ls -la /var/run/libvirt/libvirt-sock
   # Should have group 'libvirt'
   ```

2. Add your Docker user to libvirt group:
   ```bash
   sudo usermod -aG libvirt $USER
   sudo newgrp libvirt
   ```

### Issue: "libguestfs: error: could not inspect guest"

**Diagnosis**:
1. Ensure VM is powered off (required for safe conversion)
2. Verify VDDK libraries are present:
   ```bash
   ls -la /opt/vmware-vddk/lib64/
   ```
3. Check guestfs cache permissions:
   ```bash
   ls -la /var/cache/guestfs/
   ```

### Issue: "nbdkit: error: could not connect to vddk"

**Diagnosis**:
1. Verify VDDK thumbprint in .env matches ESXi host
2. Verify virt-v2v advertises VDDK support:
   ```bash
   docker exec vmigrate-worker bash -c 'virt-v2v --machine-readable | grep "^vddk$"'
   ```
3. Verify the nbdkit VDDK plugin is installed and loadable:
   ```bash
   docker exec vmigrate-worker bash -c 'nbdkit --dump-plugin vddk'
   ```
   If this reports `cannot open plugin`, the worker has nbdkit but not the VDDK plugin. Install or build `nbdkit-plugin-vddk`, then rebuild/restart the worker.
4. Enable verbose logging:
   ```bash
   # In .env, set:
   VIRT_V2V_DEBUG=1
   # Or check virt-v2v logs for details
   ```

---

## Configuration Summary

### Environment Variables
```env
# ESXi Connection (from .env)
VMWARE_ESXI_HOST=192.168.72.242        # The ESXi host IP
VMWARE_ESXI_USERNAME=root              # ESXi login username  
VMWARE_ESXI_PASSWORD=Amin@123          # ESXi login password
VMWARE_ESXI_INSECURE=true              # Skip SSL verification

# VDDK Configuration
VMWARE_ESXI_CONVERSION_TRANSPORT=vddk  # Use VDDK for disk access
VMWARE_VDDK_LIBDIR=/opt/vmware-vddk    # Path to VDDK libraries on host
VMWARE_VDDK_THUMBPRINT=7A90...         # ESXi SSL thumbprint
VMWARE_VDDK_NBDKIT_PLUGIN_PATH=/usr/lib/x86_64-linux-gnu/nbdkit/plugins
VMWARE_NBDKIT_FILTER_PATH=/usr/lib/x86_64-linux-gnu/nbdkit/filters

# Conversion Settings
ENABLE_REAL_CONVERSION=true            # Actually run virt-v2v (vs dry-run)
VIRT_V2V_TIMEOUT_SECONDS=7200          # 2-hour timeout for large VMs
MIGRATION_OUTPUT_DIR=/home/amin/shared-images  # Output path
```

### Docker Mounts (for virt-v2v)
```yaml
worker:
  volumes:
    - /opt/vmware-vddk:/opt/vmware-vddk:ro      # VDDK libraries
    - /var/run/libvirt:/var/run/libvirt:ro      # Libvirt socket
    - /etc/libvirt:/etc/libvirt:ro              # Libvirt config
    - /home/amin/shared-images:/app/shared-images  # Output directory
```

---

## References
- [virt-v2v Man Page](https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/8/html/converting_virtual_machines_to_kvm/assembly-converting-vms-from-vmware-vsphere-to-kvm_converting-vms-to-kvm#doc-wrapper)
- [virt-v2v ESXi Conversion](https://libvirt.org/formatdomainxml.html#esx-driver)
- [nbdkit-vddk-plugin](https://github.com/libguestfs/nbdkit/blob/master/plugins/vddk/README.VDDK)

---

## Summary of Changes

| File | Changes | Reason |
|------|---------|--------|
| `Dockerfile` | Added virt-v2v, libvirt, nbdkit, qemu-utils, libguestfs to worker | Missing critical tools |
| `docker-compose.yml` | Added libvirt socket/config volumes to worker | Container needs libvirt access |
| `conversion.py` | Added VM name validation and sanitization | Libvirt domain name restrictions |
| `VIRT_V2V_FIX_GUIDE.md` | Created this guide | Documentation of fixes |

---

## Next Steps

1. **Rebuild containers**: `docker-compose build --no-cache`
2. **Restart services**: `docker-compose down && docker-compose up -d`
3. **Verify installation**: Run the verification commands above
4. **Test conversion**: Submit a test migration job
5. **Monitor**: Watch the logs for successful conversion

If issues persist after these steps, please check:
- Docker logs: `docker logs vmigrate-worker`
- Backend logs: `tail -f ./backend/logs/celery.log`
- The exact error message in the MigrationJob metadata
