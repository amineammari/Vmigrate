# Air-Gapped Deployment - File Index & Quick Reference

Complete guide to all offline deployment files and their purposes.

## 📑 Documentation Files (Read in Order)

### 1. **OFFLINE_README.md** (Start Here!)
**Purpose**: Quick start guide with 5-minute setup  
**Contains**:
- Overview of what's included
- Quick start steps
- Common commands
- Basic troubleshooting
- Resource requirements

**When to read**: First thing when starting
**Time**: 2-3 minutes

### 2. **OFFLINE_DEPLOYMENT_GUIDE.md** (Comprehensive Guide)
**Purpose**: Detailed step-by-step deployment instructions  
**Contains**:
- Prerequisites and setup
- System resource requirements
- Building Docker images (3 methods)
- Loading images to air-gapped clusters
- Configuration for isolated networks
- Troubleshooting with solutions
- Kubernetes deployment examples
- Best practices

**When to read**: Before first deployment
**Time**: 10-15 minutes

### 3. **OFFLINE_CONFIG_INVENTORY.md** (Reference)
**Purpose**: Complete inventory of all tools, configs, and dependencies  
**Contains**:
- Detailed Docker image specifications
- List of all installed system packages
- All Python packages (with versions)
- All npm packages
- Volume mount specifications
- Network configuration details
- Security considerations
- Resource usage estimates
- Quick start checklist

**When to read**: When you need to understand what's included
**Time**: 5-10 minutes (can skip on first read)

### 4. **OFFLINE_DEPLOYMENT_CHECKLIST.md** (Verification)
**Purpose**: Complete setup summary with pre-deployment verification  
**Contains**:
- Status of what's been completed
- Dependency inventory (system, Python, npm, binary tools)
- Network isolation diagram
- Testing procedures
- Maintenance guidelines
- Troubleshooting matrix
- Kubernetes manifest examples
- Production recommendations

**When to read**: Before going to production
**Time**: 10 minutes

### 5. **OFFLINE_SETUP_SUMMARY.txt** (Quick Summary)
**Purpose**: ASCII summary of setup status and commands  
**Contains**:
- Completion status
- Image specifications
- 5-minute quick start
- All available commands
- Key files reference
- Configuration template
- Important warnings

**When to read**: Quick reference while working
**Time**: 2-3 minutes (for lookups)

---

## 🐳 Docker Files

### Dockerfiles for Offline Deployment

#### **docker/dockerfiles/backend-offline.Dockerfile**
- **Purpose**: Django REST API server
- **Size**: ~800MB
- **Base**: python:3.11.9-slim-bookworm
- **Key Features**:
  - Installs from `offline/wheels/` (no pip download)
  - Includes Celery, Redis, OpenStack SDK, vSphere SDK
  - Gunicorn WSGI server
  - No external network calls
- **Usage**: `docker build -f docker/dockerfiles/backend-offline.Dockerfile -t vm-migrator/backend:v1.0 .`

#### **docker/dockerfiles/conversion-worker-offline.Dockerfile**
- **Purpose**: VM conversion worker with VDDK
- **Size**: ~2.1GB
- **Base**: python:3.11.9-slim-bookworm
- **Key Features**:
  - Installs virt-v2v, libguestfs, nbdkit from Debian
  - Copies VDDK from `offline/vendor/vddk/`
  - Includes Ansible, Terraform
  - Installs from `offline/wheels/` (no pip download)
  - Runs as root (required for kernel access)
  - Pre-checks VDDK on startup
- **Usage**: `docker build -f docker/dockerfiles/conversion-worker-offline.Dockerfile -t vm-migrator/conversion-worker:v1.0 .`

#### **docker/dockerfiles/frontend-offline.Dockerfile**
- **Purpose**: React web UI
- **Size**: ~350MB
- **Base**: node:20-alpine (build + runtime)
- **Key Features**:
  - Multi-stage build
  - Bundles React app with Vite
  - Uses pre-installed node_modules
  - Serves with http-server
  - No external npm install
- **Usage**: `docker build -f docker/dockerfiles/frontend-offline.Dockerfile -t vm-migrator/frontend:v1.0 .`

---

## 🐳 Docker Compose

### **docker-compose.offline.yml**
- **Purpose**: Complete offline deployment stack
- **Services**:
  - `backend` - Django API (port 8000)
  - `frontend` - React UI (port 3000)
  - `celery-worker` - VM conversion jobs
  - `celery-beat` - Task scheduler
  - `db` - MariaDB (port 13306)
  - `redis` - Cache/queue (port 16379)
- **Network**: `control-plane-offline` (isolated, internal)
- **Volumes**: Persistent storage for data, logs, images
- **Features**:
  - Health checks for all services
  - Proper mount for `/boot` and `/lib/modules`
  - Environment-based configuration
  - All services on internal network
  - No external connections
- **Usage**:
  ```bash
  docker-compose -f docker-compose.offline.yml up -d
  docker-compose -f docker-compose.offline.yml down
  docker-compose -f docker-compose.offline.yml logs -f
  ```

---

## 🛠️ Build Automation

### **docker/scripts/build-offline.sh**
- **Purpose**: Automated build script with verification
- **Executable**: Yes (chmod +x already done)
- **Features**:
  - Pre-flight checks for offline resources
  - Validates offline/wheels/, offline/vendor/vddk/
  - Selective build options (backend-only, worker-only, etc.)
  - Version tagging support
  - Color-coded output with status
  - No-cache option for clean rebuild
- **Usage**:
  ```bash
  ./docker/scripts/build-offline.sh --ver v1.0
  ./docker/scripts/build-offline.sh --backend-only --ver v1.0
  ./docker/scripts/build-offline.sh --no-cache --ver v1.0
  ```
- **Output**: Built images tagged as vm-migrator/backend:v1.0, etc.

---

## 📦 Offline Dependencies

### **offline/wheels/** (Python Packages)
- **Content**: 67 pre-built Python .whl files
- **Size**: ~36 MB
- **Purpose**: All Python dependencies for backend and worker
- **Generated**: `pip wheel -r backend/requirements.txt -w offline/wheels/`
- **Includes**:
  - Django framework
  - Celery/Kombu task queue
  - OpenStack SDK
  - VMware vSphere SDK
  - Ansible orchestration
  - Request/HTTP libraries
  - 50+ more packages
- **Used By**: Both backend-offline and conversion-worker-offline Dockerfiles

### **offline/vendor/vddk/** (VMware VDDK SDK)
- **Content**: VMware Disk Development Kit runtime files
- **Size**: ~45 MB
- **Structure**:
  - `lib64/` - VDDK core library (libvixDiskLib.so + 40 dependencies)
  - `lib32/` - 32-bit libraries
  - `include/` - Header files (vixDiskLib.h, etc.)
  - `bin64/` - Utilities (vmware-vdiskmanager, vixDiskCheck, vddkReporter)
  - `doc/` - Documentation and samples
- **Copied From**: `/opt/vmware-vddk/` on system with VDDK installed
- **Used By**: conversion-worker-offline Dockerfile
- **Mount Path in Container**: `/opt/vmware-vddk/`

### **frontend/node_modules/** (NPM Packages)
- **Content**: All JavaScript dependencies
- **Size**: ~500 MB
- **Generated**: `npm install` in frontend/ directory
- **Includes**:
  - React 19.2.0 + ReactDOM
  - React Router 7.13.0
  - Vite 7.3.1 bundler
  - Lucide & react-icons
  - ESLint
  - 30+ more packages
- **Used By**: frontend-offline Dockerfile

---

## ⚙️ Configuration

### **.env**
- **Purpose**: Runtime environment variables
- **Location**: Root of project
- **Must Edit**: Yes! Change default passwords
- **Key Variables**:
  ```
  DB_NAME=vm_migrator
  DB_USER=vm_user
  DB_PASSWORD=admin              # ⚠️ CHANGE THIS!
  DB_ROOT_PASSWORD=rootpassword  # ⚠️ CHANGE THIS!
  VMWARE_ESXI_CONVERSION_TRANSPORT=vddk
  VMWARE_VDDK_LIBDIR=/opt/vmware-vddk
  ENABLE_REAL_CONVERSION=true
  ```
- **Used By**: All services via docker-compose.offline.yml

---

## 📊 Status Summary

| Component | Status | Location |
|-----------|--------|----------|
| Python wheels | ✅ 67 files | offline/wheels/ |
| VDDK SDK | ✅ Complete | offline/vendor/vddk/ |
| Frontend deps | ✅ Complete | frontend/node_modules/ |
| Backend Dockerfile | ✅ Created | docker/dockerfiles/backend-offline.Dockerfile |
| Worker Dockerfile | ✅ Created | docker/dockerfiles/conversion-worker-offline.Dockerfile |
| Frontend Dockerfile | ✅ Created | docker/dockerfiles/frontend-offline.Dockerfile |
| Docker Compose | ✅ Created | docker-compose.offline.yml |
| Build script | ✅ Created | docker/scripts/build-offline.sh |
| Documentation | ✅ Complete | OFFLINE_*.md files |

---

## 🚀 Common Tasks

### Build Images
```bash
./docker/scripts/build-offline.sh --ver v1.0
```

### Start Services
```bash
docker-compose -f docker-compose.offline.yml up -d
```

### View Logs
```bash
docker-compose -f docker-compose.offline.yml logs -f backend
```

### Initialize Database
```bash
docker-compose -f docker-compose.offline.yml exec backend \
  python manage.py migrate --noinput
```

### Stop Services
```bash
docker-compose -f docker-compose.offline.yml down
```

### Get Shell Access
```bash
docker-compose -f docker-compose.offline.yml exec backend bash
```

---

## ❓ FAQ

**Q: Can I use these images online (with internet)?**
A: Yes, they're just Docker images. They're optimized for offline but work fine online.

**Q: Do I need to modify the Dockerfiles?**
A: No, they're ready to use. Only edit if you add/remove Python or npm packages.

**Q: Can I use different versions?**
A: Only if you regenerate the offline dependencies. Update requirements.txt, rebuild wheels.

**Q: What if nbdkit VDDK plugin is missing?**
A: Conversion will still work using libvirt_esx transport. Update VMWARE_ESXI_CONVERSION_TRANSPORT=libvirt_esx in .env.

**Q: How do I backup my data?**
A: Docker volumes persist in `/var/lib/docker/volumes/`. Use MariaDB mysqldump for database backups.

**Q: Can I scale to multiple workers?**
A: Yes: `docker-compose -f docker-compose.offline.yml up -d --scale celery-worker=3`

**Q: How do I deploy to Kubernetes?**
A: See OFFLINE_DEPLOYMENT_GUIDE.md for K8s manifest examples.

---

## 🔗 File Relationships

```
DOCUMENTATION
├─ OFFLINE_README.md (Start here!)
├─ OFFLINE_DEPLOYMENT_GUIDE.md (Detailed guide)
├─ OFFLINE_CONFIG_INVENTORY.md (Reference)
├─ OFFLINE_DEPLOYMENT_CHECKLIST.md (Verification)
└─ OFFLINE_SETUP_SUMMARY.txt (Quick summary)

DOCKER IMAGES
├─ docker/dockerfiles/backend-offline.Dockerfile
│  └─ Uses: offline/wheels/ + backend/ code
├─ docker/dockerfiles/conversion-worker-offline.Dockerfile
│  └─ Uses: offline/wheels/ + offline/vendor/vddk/ + backend/ code
└─ docker/dockerfiles/frontend-offline.Dockerfile
   └─ Uses: frontend/node_modules/ + frontend/ code

ORCHESTRATION
└─ docker-compose.offline.yml
   ├─ Uses: All 3 Docker images
   ├─ Reads: .env configuration
   └─ Creates: Isolated network + volumes

BUILD AUTOMATION
└─ docker/scripts/build-offline.sh
   ├─ Checks: offline/wheels/, offline/vendor/vddk/
   └─ Builds: All 3 images

CONFIGURATION
└─ .env
   └─ Used by: docker-compose.offline.yml
```

---

## ✅ Pre-Deployment Verification

```bash
# Check offline resources
ls offline/wheels/ | wc -l              # Should be 67+
ls offline/vendor/vddk/                 # Should show lib64/, bin64/, etc.
ls -d frontend/node_modules             # Should exist

# Check Docker files
ls docker/dockerfiles/*-offline.Dockerfile     # Should be 3 files
ls docker-compose.offline.yml                  # Should exist
test -x docker/scripts/build-offline.sh        # Should be executable

# Check .env configured
grep DB_PASSWORD .env                   # Should be present (change!)

# Build images
./docker/scripts/build-offline.sh --ver test

# Verify images exist
docker images | grep "vm-migrator"      # Should show 3 images

# Start services
docker-compose -f docker-compose.offline.yml up -d

# Check all running
docker-compose -f docker-compose.offline.yml ps  # All should be "Up"

# Test API
curl http://localhost:8000/api/health/  # Should return 200

# Verify complete
echo "✅ Air-gapped deployment ready!"
```

---

## 📞 Support Resources

- Docker Docs: https://docs.docker.com
- Docker Compose Docs: https://docs.docker.com/compose
- virt-v2v: https://libguestfs.org/virt-v2v
- Django: https://docs.djangoproject.com
- Celery: https://docs.celeryproject.org

---

**Last Updated**: May 11, 2026  
**Status**: ✅ Complete and Ready  
**Version**: 1.0
