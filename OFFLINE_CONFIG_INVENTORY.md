# Air-Gapped Configuration Inventory

Complete manifest of all configurations, tools, and dependencies included in the offline deployment.

## 📦 Docker Images Configuration

### 1. Backend Image (`backend-offline.Dockerfile`)

**Purpose**: Django REST API server, Celery broker, Task management UI

**Base Image**: `python:3.11.9-slim-bookworm`

**Installed System Packages**:
- `default-libmysqlclient-dev` - MySQL client development files
- `gcc` - C compiler for building Python extensions
- `openssh-client` - SSH for remote operations
- `pkg-config` - Package configuration tool

**Python Packages** (from `offline/wheels/`):
```
Core Django & REST:
- Django==4.2.16
- djangorestframework==3.16.1
- djangorestframework-simplejwt==5.5.1
- django-environ==0.12.0
- whitenoise==6.8.2 (static file serving)

Async Queue:
- celery==5.6.2
- kombu==5.6.2
- redis==7.1.1

Database:
- mysqlclient==2.2.8
- psycopg2-binary==2.9.11 (PostgreSQL support)

Cloud & Virtualization:
- openstacksdk==4.9.0
- pyvmomi==9.0.0.0 (vSphere API)
- keystoneauth1==5.13.0

Utilities:
- gunicorn==23.0.0 (production WSGI server)
- requests==2.32.5
- pyyaml==6.0.3
- jsonpatch==1.33
```

**Entrypoints**:
- `/usr/local/bin/backend-entrypoint` → gunicorn server
- `/usr/local/bin/celery-worker-entrypoint` → general task worker
- `/usr/local/bin/celery-beat-entrypoint` → scheduled task daemon

**Environment Variables**:
```
DJANGO_SETTINGS_MODULE=core.settings
DATABASE_URL=mysql://...
REDIS_URL=redis://...
```

**Exposed Ports**: 8000 (Gunicorn HTTP)

---

### 2. Conversion Worker Image (`conversion-worker-offline.Dockerfile`)

**Purpose**: Process VM disk conversion jobs (ESXi → OpenStack/KVM)

**Base Image**: `python:3.11.9-slim-bookworm`

**Installed System Packages**:
```
Virtualization & Disk Tools:
- virt-v2v - Disk conversion engine
- libguestfs-tools - Guest filesystem tools
- libguestfs-xfs - XFS filesystem support
- libguestfs-reiserfs - ReiserFS filesystem support
- guestfs-tools - Guest tools
- qemu-utils - QEMU disk tools
- libvirt-clients - libvirt command-line tools

File Formats & Archives:
- xz-utils - XZ compression
- unzip - ZIP extraction

Networking:
- openssh-client, iproute2, rsync

Plugins:
- nbdkit - Network block device server
- nbdkit-plugin-guestfs - libguestfs plugin for nbdkit
- nbdkit-plugin-libvirt - libvirt plugin for nbdkit

Libraries:
- libaugeas0 - Configuration file editing
- libxml2 - XML parsing
- ca-certificates - SSL/TLS certificates
- jq - JSON processor
```

**Python Packages** (same as backend + extras):
```
All backend packages plus:
- ansible-core==2.17.7
- pytest==9.0.0 (testing framework)
```

**Vendored Files**:
- `offline/vendor/vddk/` → `/opt/vmware-vddk/`
  - `lib64/libvixDiskLib.so` - Core VDDK library
  - `lib64/*.so` - 40+ supporting libraries
  - `include/*.h` - Header files
  - `bin64/` - Utilities (vddkReporter, vixDiskCheck, vmware-vdiskmanager)

**Scripts**:
- `/usr/local/bin/conversion-worker-entrypoint` - Task entrypoint
- `/usr/local/bin/conversion-worker-preflight` - VDDK/libguestfs runtime checks
- `/usr/local/bin/conversion-worker-healthcheck` - Celery worker health

**Environment Variables**:
```
DJANGO_SETTINGS_MODULE=core.settings
MIGRATION_OUTPUT_DIR=/var/lib/vm-migrator/images
VMWARE_VDDK_LIBDIR=/opt/vmware-vddk
VMWARE_VDDK_CONFIG=/opt/vmware-vddk/lib64
LD_LIBRARY_PATH=/opt/vmware-vddk/lib64:$LD_LIBRARY_PATH
LIBGUESTFS_BACKEND=direct
```

**Celery Queues**: migrations, discovery, provisioning, celery

---

### 3. Frontend Image (`frontend-offline.Dockerfile`)

**Purpose**: React web UI for managing migrations

**Build Stage**: `node:20-alpine`

**Runtime Stage**: `node:20-alpine`

**NPM Dependencies** (from `frontend/package.json`):
```
Production:
- react==19.2.0
- react-dom==19.2.0
- react-router-dom==7.13.0
- lucide-react==1.14.0 (icon library)
- react-icons==5.6.0

Dev Dependencies:
- vite==7.3.1 (bundler)
- @vitejs/plugin-react==5.1.1
- eslint==9.39.1
- typescript support via @types packages
```

**Build Output**: Static files in `/app/dist/`

**Serve Tool**: `http-server` (lightweight HTTP server)

**Exposed Port**: 3000

---

## 🔧 Tools & Utilities Included

### Ansible (Conversion Worker)

- **Version**: ansible-core==2.17.7
- **Location**: `/app/ansible/`
- **Playbooks**: Conversion orchestration
- **Inventory**: ESXi/OpenStack hosts management

### Terraform (Conversion Worker)

- **Version**: 1.7.5
- **Binary**: Bundled in image
- **Cache Directory**: `/opt/terraform/plugin-cache`
- **Module Location**: `/app/terraform/`
- **Providers**: OpenStack, vSphere, local

### virt-v2v (Conversion Worker)

- **Source**: Debian bookworm package
- **Purpose**: Windows/Linux VM disk conversion
- **Supports**: 
  - VMware vSphere → QEMU/KVM (via VDDK or libvirt)
  - ESXi → OpenStack (via virt-v2v)
  - VMDK/VDI → QCOW2

### libguestfs (Conversion Worker)

- **Components**: guestfs-tools, libguestfs-tools
- **Purpose**: Guest filesystem inspection & modification
- **Supermin Kernel**: Read from host `/boot/vmlinuz-*`
- **Cache**: `/var/cache/guestfs/`

### nbdkit (Conversion Worker)

- **Version**: Debian package
- **Plugins Enabled**:
  - guestfs plugin (filesystem access)
  - libvirt plugin (ESXi/vSphere access via libvirt)
  - vddk plugin (if available, direct VDDK disk access)

---

## 📋 Volume Mounts

### Backend Service

| Mount | Type | Purpose |
|-------|------|---------|
| `/app/staticfiles` | persistent | Static web assets (CSS, JS, images) |
| `/app/logs` | persistent | Application and request logs |

### Conversion Worker Service

| Mount | Type | Purpose |
|-------|------|---------|
| `/var/lib/vm-migrator/images` | persistent | Converted disk images |
| `/app/logs` | persistent | Worker task logs |
| `/boot` | host read-only | Kernel files for libguestfs supermin |
| `/lib/modules` | host read-only | Module files for supermin |

### Celery Beat Service

| Mount | Type | Purpose |
|-------|------|---------|
| `/app/logs` | persistent | Scheduler logs |
| `/var/lib/vm-migrator/beat` | persistent | Schedule database |

### Database Service

| Mount | Type | Purpose |
|-------|------|---------|
| `mariadb-data-offline` | persistent | MariaDB data files |

### Redis Service

| Mount | Type | Purpose |
|-------|------|---------|
| `redis-data-offline` | persistent | Redis snapshots (RDB/AOF) |

---

## 🌐 Network Configuration

### docker-compose.offline.yml

**Network**: `control-plane-offline` (bridge, internal)

**Service Aliases**:
```
db → vmigrate-db (port 3306)
redis → vmigrate-redis (port 6379)
backend → vmigrate-backend (port 8000)
frontend → vmigrate-frontend (port 3000)
celery-worker → conversion-worker (internal)
celery-beat → celery-beat (internal)
```

**No External Reaches**: All services communicate internally

---

## 📊 Database & Cache

### MariaDB (Service: `db`)

- **Image**: `mariadb:10.11.8`
- **Database**: `vm_migrator`
- **User**: `vm_user`
- **Connections**: Backend, Celery Beat
- **Built-in Migrations**: Django ORM + custom migrations

### Redis (Service: `redis`)

- **Image**: `redis:7.2.5-alpine`
- **Persistence**: AOF (Append-Only File) enabled
- **Databases**: 0 (broker), 1 (result backend)
- **Memory Policies**: `maxmemory-policy` LRU by default

---

## ⚙️ Configuration Files

### .env (Required)

```bash
# Database
DB_ROOT_PASSWORD=rootpassword
DB_NAME=vm_migrator
DB_USER=vm_user
DB_PASSWORD=admin

# Ports
DB_PUBLISHED_PORT=13306
REDIS_PUBLISHED_PORT=16379
BACKEND_PUBLISHED_PORT=8000
FRONTEND_PUBLISHED_PORT=3000

# VDDK Configuration
VMWARE_ESXI_CONVERSION_TRANSPORT=vddk
VMWARE_VDDK_LIBDIR=/opt/vmware-vddk

# Features
ENABLE_REAL_CONVERSION=true
ENABLE_ANSIBLE_CONVERSION=false
ENABLE_TERRAFORM_FROM_CELERY=false

# Django
DJANGO_SECRET_KEY=your-secret-key-here
DEBUG=false
```

### backend/requirements.txt

Lists all 60+ Python dependencies with pinned versions

### frontend/package.json

Lists all 40+ NPM packages with ~version specifications

---

## 🔐 Security Considerations

### Air-Gapped Deployment Assumptions

1. **No Internet Access** - Container cannot reach external registries or repos
2. **Trusted Build Tools** - Dockerfile build happens on trusted machine before transfer
3. **Signed Images** - Optionally sign images before deployment
4. **Registry Authentication** - If using private registry, authenticate securely
5. **Secret Management** - .env file contains DB passwords; protect with file permissions

### No External Dependencies

```bash
# Verification: No curl/wget/apt-get in running images
docker run --rm vm-migrator/backend:offline bash -c "which curl wget" || echo "✓ No curl/wget available"

# Verification: All dependencies pre-packaged
docker run --rm vm-migrator/conversion-worker:offline pip list | wc -l # Should show 60+
```

---

## 📈 Resource Usage

### Image Sizes

| Image | Size | Build Time |
|-------|------|------------|
| backend-offline | ~800MB | 4-5 min |
| conversion-worker-offline | ~2.1GB | 8-10 min |
| frontend-offline | ~350MB | 2-3 min |
| **Total** | **~3.2GB** | **~15 min** |

### Runtime Memory Usage (Per Service)

| Service | Min | Typical | Peak |
|---------|-----|---------|------|
| backend | 256MB | 512MB | 1GB |
| conversion-worker | 512MB | 1.5GB | 3GB+ (during conversion) |
| frontend | 64MB | 128MB | 256MB |
| mariadb | 256MB | 512MB | 1GB |
| redis | 128MB | 256MB | 512MB |

### Disk Usage (Mounted Volumes)

| Volume | Expected Size | Notes |
|--------|---------------|-------|
| mariadb-data-offline | 100MB-1GB | Grows with migration history |
| redis-data-offline | 10-100MB | Depends on queue depth |
| migration-images-offline | 50GB+ | Where VMDK/QCOW2 images live |
| backend-logs-offline | 1-10GB | Log rotation should be configured |

---

## ✅ Pre-Deployment Checklist

- [ ] `offline/wheels/` populated (60+ .whl files)
- [ ] `offline/vendor/vddk/` populated (bin64/, lib64/, include/) 
- [ ] `frontend/node_modules/` exists (npm install done)
- [ ] `.env` file configured with credentials & ports
- [ ] Docker daemon running with 50GB+ free space
- [ ] All 3 images built: `docker images | grep vm-migrator`
- [ ] backend image exports port 8000
- [ ] conversion-worker image validates VDDK at startup
- [ ] frontend image builds React assets successfully
- [ ] MariaDB image pulled from registry (only registry access needed)
- [ ] Redis image pulled from registry (only registry access needed)

---

## 🚀 Quick Start

```bash
# 1. Prepare offline resources
pip wheel -r backend/requirements.txt -w offline/wheels/
sudo cp -r /opt/vmware-vddk/* offline/vendor/vddk/
cd frontend && npm install && cd ..

# 2. Build images
./docker/scripts/build-offline.sh --ver v1.0

# 3. Configure environment
cp .env.example .env
# Edit .env with actual credentials

# 4. Deploy
docker-compose -f docker-compose.offline.yml up -d

# 5. Verify
docker-compose -f docker-compose.offline.yml ps
curl http://localhost:8000/api/health/
```

---

**Last Updated**: May 2026  
**Applicable Versions**: vm-migrator 1.0+, Docker Compose 3.8+
