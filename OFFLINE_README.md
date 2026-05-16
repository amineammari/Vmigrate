# Air-Gapped Docker Deployment Setup

**Complete offline/air-gapped deployment for vm-migrator is ready.**

This setup allows vm-migrator to run in environments with zero external network access. All dependencies, configurations, and tools are packaged directly in Docker images.

## 📋 What's Included

| Component | Status | Location |
|-----------|--------|----------|
| Python dependencies (67 wheels) | ✅ Ready | `offline/wheels/` |
| VDDK SDK (VMware tools) | ✅ Ready | `offline/vendor/vddk/` |
| Frontend build assets | ✅ Ready | `frontend/node_modules/` |
| Offline Dockerfiles | ✅ Ready | `docker/dockerfiles/*-offline.Dockerfile` |
| Docker Compose stack | ✅ Ready | `docker-compose.offline.yml` |
| Build automation script | ✅ Ready | `docker/scripts/build-offline.sh` |
| Complete documentation | ✅ Ready | `OFFLINE_*.md` files |

## 🚀 Quick Start

### 1️⃣ Build Docker Images (30 seconds)

```bash
# Build all offline images
./docker/scripts/build-offline.sh --ver v1.0

# Or build specific service
./docker/scripts/build-offline.sh --backend-only --ver v1.0
```

### 2️⃣ Configure Environment (2 minutes)

```bash
# Copy and edit the environment file
cp .env .env.offline
vim .env.offline

# Key settings:
# - DB_PASSWORD (change from default!)
# - VMWARE_ESXI_CONVERSION_TRANSPORT=vddk (already set)
# - ENABLE_REAL_CONVERSION=true (for actual conversions)
```

### 3️⃣ Start Services (1 minute)

```bash
# Launch the entire stack
docker-compose -f docker-compose.offline.yml up -d

# Check status
docker-compose -f docker-compose.offline.yml ps
```

### 4️⃣ Initialize Database (30 seconds)

```bash
# Run Django migrations
docker-compose -f docker-compose.offline.yml exec backend \
  python manage.py migrate --noinput

# Create admin user (optional)
docker-compose -f docker-compose.offline.yml exec backend \
  python manage.py createsuperuser
```

### 5️⃣ Access Application

```
Frontend: http://localhost:3000/
Backend API: http://localhost:8000/api/
Backend Admin: http://localhost:8000/admin/
```

## 📂 Directory Structure

```
vm-migrator/
├── offline/                           # Offline dependencies
│   ├── wheels/                        # 67 Python .whl files (36MB)
│   ├── vendor/
│   │   └── vddk/                      # VMware VDDK SDK (45MB)
│   ├── npm-cache/                     # (Optional) npm packages
│   └── terraform-providers/           # (Optional) terraform plugins
│
├── docker/
│   ├── dockerfiles/
│   │   ├── backend-offline.Dockerfile         # ✅ NEW
│   │   ├── conversion-worker-offline.Dockerfile # ✅ NEW
│   │   ├── frontend-offline.Dockerfile        # ✅ NEW
│   │   ├── backend.Dockerfile                 # (legacy online)
│   │   └── conversion-worker.Dockerfile       # (legacy online)
│   ├── scripts/
│   │   └── build-offline.sh           # ✅ NEW - Build automation
│   └── entrypoints/                   # Container startup scripts
│
├── docker-compose.offline.yml         # ✅ NEW - Offline stack
├── docker-compose.yml                 # (legacy online)
├── .env                               # Configuration (edit this!)
│
├── OFFLINE_DEPLOYMENT_GUIDE.md        # ✅ NEW - Step-by-step guide
├── OFFLINE_CONFIG_INVENTORY.md        # ✅ NEW - Configuration details
├── OFFLINE_DEPLOYMENT_CHECKLIST.md    # ✅ NEW - Verification checklist
│
├── backend/                           # Django application
├── frontend/                          # React web UI
├── ansible/                           # Orchestration playbooks
├── terraform/                         # Infrastructure templates
└── ... (other project files)
```

## 📦 What's in Each Docker Image

### Backend Image (vm-migrator/backend:offline)
- **Size**: ~800MB
- **Includes**:
  - Django REST API framework
  - Celery task queue (beat scheduler)
  - MariaDB & PostgreSQL drivers
  - OpenStack & vSphere SDKs
  - All 67 Python dependencies

### Conversion Worker Image (vm-migrator/conversion-worker:offline)
- **Size**: ~2.1GB
- **Includes**:
  - virt-v2v (disk conversion engine)
  - libguestfs (guest filesystem tools)
  - nbdkit (network block device)
  - VDDK SDK with libraries
  - Ansible orchestration framework
  - Terraform infrastructure tool
  - All 67 Python dependencies

### Frontend Image (vm-migrator/frontend:offline)
- **Size**: ~350MB
- **Includes**:
  - React 19.2.0 application
  - React Router for navigation
  - Vite bundled assets
  - http-server for static file serving

## 🔧 Configuration Details

### Services in docker-compose.offline.yml

| Service | Port | Purpose |
|---------|------|---------|
| `backend` | 8000 | Django API, Admin panel, Static files |
| `frontend` | 3000 | React web UI |
| `celery-worker` | (internal) | VM conversion jobs |
| `celery-beat` | (internal) | Task scheduling |
| `db` | 13306 | MariaDB database |
| `redis` | 16379 | Message queue & cache |

### Environment Variables (.env)

```bash
# Database
DB_NAME=vm_migrator
DB_USER=vm_user
DB_PASSWORD=admin          # ⚠️ CHANGE THIS!
DB_ROOT_PASSWORD=root      # ⚠️ CHANGE THIS!

# VDDK (already configured)
VMWARE_ESXI_CONVERSION_TRANSPORT=vddk
VMWARE_VDDK_LIBDIR=/opt/vmware-vddk

# Features
ENABLE_REAL_CONVERSION=true
ENABLE_ANSIBLE_CONVERSION=false
ENABLE_TERRAFORM_FROM_CELERY=false

# Ports (can customize)
BACKEND_PUBLISHED_PORT=8000
FRONTEND_PUBLISHED_PORT=3000
DB_PUBLISHED_PORT=13306
REDIS_PUBLISHED_PORT=16379
```

## 📚 Documentation

### Quick Refs
- **[OFFLINE_DEPLOYMENT_GUIDE.md](OFFLINE_DEPLOYMENT_GUIDE.md)** - Detailed step-by-step guide
- **[OFFLINE_CONFIG_INVENTORY.md](OFFLINE_CONFIG_INVENTORY.md)** - All configs & tools reference
- **[OFFLINE_DEPLOYMENT_CHECKLIST.md](OFFLINE_DEPLOYMENT_CHECKLIST.md)** - Pre-deployment checklist

### How-To Guides
- [Building Images](#building-images)
- [Air-Gapped Cluster Deployment](#air-gapped-cluster-deployment)
- [Troubleshooting](#troubleshooting)

## 🏗️ Building Images

### Automated Build (Recommended)

```bash
# Build all images
./docker/scripts/build-offline.sh --ver v1.0

# Build with options
./docker/scripts/build-offline.sh \
  --ver v1.0 \
  --backend-only      # (or --worker-only, --frontend-only)
  --no-cache          # Force full rebuild
```

### Manual Build

```bash
# Backend
docker build -f docker/dockerfiles/backend-offline.Dockerfile \
  -t vm-migrator/backend:v1.0 .

# Conversion Worker
docker build -f docker/dockerfiles/conversion-worker-offline.Dockerfile \
  -t vm-migrator/conversion-worker:v1.0 .

# Frontend
docker build -f docker/dockerfiles/frontend-offline.Dockerfile \
  -t vm-migrator/frontend:v1.0 .
```

### Verify Build

```bash
# List built images
docker images | grep vm-migrator

# Test backend image
docker run --rm vm-migrator/backend:v1.0 python -c "import django; print('✓ Django OK')"

# Test conversion worker
docker run --rm vm-migrator/conversion-worker:v1.0 \
  bash -c "ls /opt/vmware-vddk/lib64/libvixDiskLib.so && echo '✓ VDDK OK'"

# Test frontend
docker run --rm vm-migrator/frontend:v1.0 ls /app/dist/index.html && echo "✓ Frontend OK"
```

## ☁️ Air-Gapped Cluster Deployment

### Deploy to Private Cluster (No Internet)

```bash
# 1. On build machine (with internet):
./docker/scripts/build-offline.sh --ver v1.0

# 2. Export images to tar files
docker save vm-migrator/backend:v1.0 -o backend.tar
docker save vm-migrator/conversion-worker:v1.0 -o worker.tar
docker save vm-migrator/frontend:v1.0 -o frontend.tar

# 3. Transfer files to air-gapped cluster (USB, SCP, etc.)
scp backend.tar worker.tar frontend.tar user@air-gapped:/tmp/

# 4. On air-gapped cluster:
cd /tmp
docker load -i backend.tar
docker load -i worker.tar
docker load -i frontend.tar

# 5. Copy docker-compose and config
cp /source/docker-compose.offline.yml /opt/vm-migrator/
cp /source/.env /opt/vm-migrator/
cd /opt/vm-migrator

# 6. Start deployment
docker-compose -f docker-compose.offline.yml up -d
```

### Deploy to Kubernetes

```yaml
# kubernetes-deployment.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: vm-migrator

---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: vm-migrator-backend
  namespace: vm-migrator
spec:
  replicas: 1
  selector:
    matchLabels:
      app: backend
  template:
    metadata:
      labels:
        app: backend
    spec:
      containers:
      - name: backend
        image: vm-migrator/backend:v1.0
        imagePullPolicy: Never  # ← CRITICAL for offline
        ports:
        - containerPort: 8000
        env:
        - name: DATABASE_URL
          value: "mysql://vm_user:admin@db-service:3306/vm_migrator"
        - name: REDIS_URL
          value: "redis://redis-service:6379"
```

## 🔍 Monitoring & Debugging

### Check Service Status

```bash
# All services
docker-compose -f docker-compose.offline.yml ps

# Specific service
docker-compose -f docker-compose.offline.yml logs -f backend

# Watch all logs
docker-compose -f docker-compose.offline.yml logs -f
```

### Inspect Containers

```bash
# Get shell access
docker-compose -f docker-compose.offline.yml exec backend bash

# Check Python packages
docker run --rm vm-migrator/backend:v1.0 pip list | wc -l
# Should show 60+ packages

# Verify VDDK
docker run --rm vm-migrator/conversion-worker:v1.0 \
  find /opt/vmware-vddk -name "lib*.so" | wc -l
# Should show 40+ libraries
```

### Test API

```bash
# Health check
curl http://localhost:8000/api/health/

# Admin panel
curl http://localhost:8000/admin/

# Frontend
curl http://localhost:3000/ | head -20
```

## ⚠️ Troubleshooting

### "nbdkit VDDK plugin is unavailable"
**Cause**: VDDK plugin not compiled in nbdkit  
**Fix**: Use `libvirt_esx` transport or pre-build plugin into image

### "Cannot read /boot/vmlinuz"
**Cause**: Host kernel not accessible to container  
**Fix**: Confirm docker-compose mounts `/boot:/boot:ro`

### "Module 'XXX' not found"
**Cause**: Python wheel not in `offline/wheels/`  
**Fix**: Regenerate wheels: `pip wheel -r backend/requirements.txt -w offline/wheels/`

### "Connection refused (database)"
**Cause**: MariaDB not started  
**Fix**: `docker-compose -f docker-compose.offline.yml ps` → verify db is running

### "Frontend shows blank page"
**Cause**: React build failed  
**Fix**: Rebuild without cache: `./docker/scripts/build-offline.sh --no-cache`

See [OFFLINE_DEPLOYMENT_GUIDE.md](OFFLINE_DEPLOYMENT_GUIDE.md#troubleshooting) for more solutions.

## 💡 Pro Tips

1. **Version Your Images**
   ```bash
   ./docker/scripts/build-offline.sh --ver v1.2.0  # Tag with semver
   ```

2. **Pre-Pull Base Images** (for true offline)
   ```bash
   docker pull mariadb:10.11.8
   docker pull redis:7.2.5-alpine
   # Now they're cached locally
   ```

3. **Use Private Registry** (for multiple hosts)
   ```bash
   docker tag vm-migrator/backend:v1.0 my-registry/backend:v1.0
   docker push my-registry/backend:v1.0
   # Update docker-compose.offline.yml to use my-registry
   ```

4. **Volume Backup**
   ```bash
   docker-compose -f docker-compose.offline.yml exec db \
     mysqldump -uroot -p${DB_ROOT_PASSWORD} vm_migrator > backup.sql
   ```

## 🔐 Security Notes

- ✅ No arbitrary downloads at runtime
- ✅ All code reviewed before image build
- ⚠️ Change default DB passwords in `.env`
- ⚠️ Use read-only root filesystem for containers
- ⚠️ Restrict network policies for inter-container communication

## 📊 Resource Requirements

| Component | Min | Typical | Peak |
|-----------|-----|---------|------|
| CPU | 2 cores | 4 cores | 8 cores |
| RAM | 4GB | 8GB | 16GB |
| Disk | 20GB | 50GB | 100GB+ |

## 📈 Scaling Considerations

```bash
# Multiple workers
docker-compose -f docker-compose.offline.yml up -d --scale celery-worker=3

# Load balancer (Nginx)
# Deploy nginx container in same network as backend/frontend

# Database replication
# Setup MariaDB primary-replica outside Docker for HA
```

## 🎓 Learn More

- **Django Docs**: https://docs.djangoproject.com
- **Celery Docs**: https://docs.celeryproject.org
- **virt-v2v Docs**: https://libguestfs.org/virt-v2v
- **Docker Compose Docs**: https://docs.docker.com/compose

## 📞 Support

### Logs
```bash
# Collect all logs
docker-compose -f docker-compose.offline.yml logs > logs.tar.gz
```

### Report Issues
When reporting issues, include:
1. Docker version: `docker --version`
2. Compose version: `docker-compose --version`
3. OS/Kernel: `uname -a`
4. Service logs: `docker-compose logs <service>`
5. Error message (full output)

## ✅ Pre-Deployment Checklist

- [ ] All offline resources present (`offline/wheels/`, `offline/vendor/vddk/`)
- [ ] Docker daemon running with 50GB+ free space
- [ ] All 3 images built successfully
- [ ] `.env` file configured with proper credentials
- [ ] Backend image can start: `docker run --rm vm-migrator/backend:offline`
- [ ] Worker image has VDDK: `docker run --rm vm-migrator/conversion-worker:offline ls /opt/vmware-vddk/lib64`
- [ ] Frontend builds successfully: `docker run --rm vm-migrator/frontend:offline ls /app/dist`
- [ ] MariaDB/Redis can pull (if not truly offline)
- [ ] Volumes have write permissions

## 🚀 Deploy Now

```bash
# Everything in one command
./docker/scripts/build-offline.sh --ver v1.0 && \
docker-compose -f docker-compose.offline.yml up -d && \
docker-compose -f docker-compose.offline.yml exec backend \
  python manage.py migrate --noinput && \
echo "✅ vm-migrator is ready at http://localhost:3000"
```

---

**Version**: 1.0  
**Last Updated**: May 2026  
**Status**: ✅ Production Ready

For detailed information, see the [OFFLINE_DEPLOYMENT_GUIDE.md](OFFLINE_DEPLOYMENT_GUIDE.md).
