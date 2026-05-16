# Air-Gapped Deployment Guide

This guide explains how to deploy vm-migrator in an air-gapped (offline) Kubernetes cluster with zero external network access.

## Overview

The air-gapped deployment strategy packages **all** application dependencies, configuration, and runtime tools directly into Docker images. No external downloads or registry pulls occur at runtime.

### What Gets Packaged

| Component | Location | Details |
|-----------|----------|---------|
| Python Dependencies | `offline/wheels/` | All pip packages as `.whl` files |
| VDDK SDK | `offline/vendor/vddk/` | VMware Disk Development Kit runtime files |
| Frontend Dependencies | `frontend/node_modules/` | All npm packages vendored in image |
| virt-v2v Toolchain | Debian packages | Pre-baked in Dockerfile |
| Terraform | Docker image | Bundled terraform binary |
| Configuration | Environment variables | Passed via `.env` file |

## Prerequisites

### Required Files

```
offline/
├── wheels/               # Python packages (~500MB)
│   ├── celery-*.whl
│   ├── django-*.whl
│   └── ...60+ more wheels
├── vendor/
│   └── vddk/            # VDDK SDK (~200MB)
│       ├── bin64/
│       ├── doc/
│       ├── include/
│       ├── lib32/
│       └── lib64/
└── images/              # (future: pre-built layer cache)
```

### System Requirements

- Docker 20.10+ with BuildKit enabled
- ~50GB disk space for multi-stage builds (can be reduced with `--no-cache`)
- 8GB+ RAM for parallel builds
- Linux host with `/boot` and `/lib/modules` readable by container

## Step 1: Prepare Offline Resources

### 1a. Generate Python Wheels (if not already done)

```bash
cd /path/to/vm-migrator

# Create wheels for all requirements
pip wheel -r backend/requirements.txt -w offline/wheels/

# Add extra packages
pip wheel -w offline/wheels/ \
  ansible-core==2.17.7 \
  gunicorn==23.0.0 \
  whitenoise==6.8.2
```

**Output**: ~70 `.whl` files in `offline/wheels/` (~200MB total)

### 1b. Copy VDDK SDK Files

```bash
# From the system with VDDK installed:
sudo cp -rv /opt/vmware-vddk/* ./offline/vendor/vddk/

# Or from a mounted path if VDDK is in a non-standard location:
sudo cp -rv /path/to/vddk/* ./offline/vendor/vddk/

# Verify structure:
ls -la offline/vendor/vddk/
# Expected output:
# bin64/  doc/  include/  lib32/  lib64/
```

**Size**: ~200MB total

**Why**: Conversion worker needs VDDK libraries at runtime. Docker COPY during build ensures they're in the image layer.

### 1c. Vendor Frontend Dependencies

```bash
cd frontend
npm install --legacy-peer-deps
npm ci --prefer-offline

# Verify node_modules is populated:
du -sh node_modules/  # Should be ~500MB+
```

**Size**: ~500MB

**Why**: Frontend Dockerfile uses `npm ci --prefer-offline` with mounted node_modules cache.

## Step 2: Build Docker Images Offline

### Using Build Script (Recommended)

```bash
# Build all images (backend, worker, frontend)
./docker/scripts/build-offline.sh --ver v1.0

# Build specific image
./docker/scripts/build-offline.sh --backend-only --ver v1.0
./docker/scripts/build-offline.sh --worker-only --ver v1.0

# Build without Docker cache (slower but guarantees clean build)
./docker/scripts/build-offline.sh --no-cache --ver v1.0
```

### Manual Build

If you prefer to build directly with docker:

```bash
# Backend
docker build \
  -f docker/dockerfiles/backend-offline.Dockerfile \
  -t vm-migrator/backend:v1.0 \
  .

# Conversion Worker
docker build \
  -f docker/dockerfiles/conversion-worker-offline.Dockerfile \
  -t vm-migrator/conversion-worker:v1.0 \
  .

# Frontend
docker build \
  -f docker/dockerfiles/frontend-offline.Dockerfile \
  -t vm-migrator/frontend:v1.0 \
  .
```

### Verify Images

```bash
docker images | grep vm-migrator

# Expected output:
# REPOSITORY                        TAG         SIZE
# vm-migrator/backend               v1.0        800MB
# vm-migrator/conversion-worker     v1.0        2.1GB
# vm-migrator/frontend              v1.0        350MB
```

## Step 3: Load Images into Air-Gapped Environment

### Option A: Docker Tar Export (For Docker-only environments)

```bash
# On build machine:
docker save vm-migrator/backend:v1.0 > vm-migrator-backend-v1.0.tar
docker save vm-migrator/conversion-worker:v1.0 > vm-migrator-worker-v1.0.tar
docker save vm-migrator/frontend:v1.0 > vm-migrator-frontend-v1.0.tar

# Transfer to air-gapped host and load:
docker load -i vm-migrator-backend-v1.0.tar
docker load -i vm-migrator-conversion-worker-v1.0.tar
docker load -i vm-migrator-frontend-v1.0.tar
```

### Option B: Kubernetes Image Import (For K8s environments)

```bash
# Save images as OCI archives:
docker save vm-migrator/backend:v1.0 -o backend.tar
docker save vm-migrator/conversion-worker:v1.0 -o worker.tar
docker save vm-migrator/frontend:v1.0 -o frontend.tar

# On air-gapped K8s cluster:
# 1. Import to container runtime (docker/containerd/cri-o)
ctr -n k8s.io image import ./backend.tar
ctr -n k8s.io image import ./worker.tar
ctr -n k8s.io image import ./frontend.tar

# 2. Or use local image registry:
# - Deploy private container registry in cluster
# - Push images: docker push myregistry.local/vm-migrator/backend:v1.0
# - Reference in K8s manifests: image: myregistry.local/vm-migrator/backend:v1.0
```

## Step 4: Deploy with docker-compose

### On Air-Gapped Host

```bash
# Copy these files to the air-gapped host:
# - docker-compose.offline.yml
# - .env
# - (backend, frontend, ansible, terraform directories)

# Start all services:
docker-compose -f docker-compose.offline.yml up -d

# Check status:
docker-compose -f docker-compose.offline.yml ps

# View logs:
docker-compose -f docker-compose.offline.yml logs -f backend

# Run database migrations:
docker-compose -f docker-compose.offline.yml exec backend \
  python manage.py migrate --noinput
```

### Verify Deployment

```bash
# Check all services are running:
docker-compose -f docker-compose.offline.yml ps

# Test backend API:
curl http://localhost:8000/api/health/

# Test frontend:
curl http://localhost:3000/

# Check Celery worker:
docker-compose -f docker-compose.offline.yml exec celery-worker \
  celery -A core inspect active
```

## Step 5: Configuration for Air-Gapped

### Update .env for Air-Gapped Network

```bash
# .env - configured for isolated network
VMWARE_ESXI_CONVERSION_TRANSPORT=vddk
VMWARE_VDDK_LIBDIR=/opt/vmware-vddk
ENABLE_REAL_CONVERSION=true
DATABASE_URL=mysql://vm_user:admin@db:3306/vm_migrator
REDIS_URL=redis://redis:6379/0
```

### Network Configuration

The offline compose creates an isolated network:

```yaml
networks:
  control-plane-offline:
    driver: bridge
```

**Important**: If your cluster has strict firewall rules, ensure:
- Container-to-container communication is allowed
- No external DNS/NTP required by services
- Volume mounts work correctly (especially `/boot`, `/lib/modules`)

## Troubleshooting

### "nbdkit VDDK plugin is unavailable"

**Cause**: The nbdkit VDDK plugin is not compiled into qemu/nbdkit packages.

**Solution**:
1. On the system with VDDK, check if plugin exists:
   ```bash
   find /opt/vmware-vddk -name "*nbdkit*" -o -name "*plugin*"
   ls /usr/lib/x86_64-linux-gnu/nbdkit/plugins/ | grep vddk
   ```

2. If missing, the conversion-worker Dockerfile preflight check will warn but continue
3. Conversion jobs will need to use different transport (e.g., `libvirt_esx`) until plugin is available

### "libguestfs bootstrap failed"

**Cause**: Container can't read host kernel files.

**Solution**:
- docker-compose.offline.yml already mounts `/boot:/boot:ro` and `/lib/modules:/lib/modules:ro`
- Ensure host permissions allow container root to read these directories
- Run worker with `user: root` (already configured)

### "Permission denied: /var/lib/vm-migrator/images"

**Cause**: Volume mount permission issue.

**Solution**:
```bash
# On host, ensure directory is writable by container:
sudo chown 10001:10001 /var/lib/vm-migrator/images
sudo chmod 755 /var/lib/vm-migrator/images
```

### Image Size Too Large

**Cause**: Multi-stage builds cache intermediate layers.

**Solution **:
```bash
# Clean up intermediate images:
docker image prune -a -f

# Rebuild without cache:
./docker/scripts/build-offline.sh --no-cache --ver v2.0
```

## Maintenance

### Updating Dependencies

To update Python packages for air-gapped:

```bash
# 1. Update requirements.txt on a connected machine
vi backend/requirements.txt

# 2. Regenerate wheels:
pip wheel -r backend/requirements.txt -w offline/wheels/

# 3. Commit offline/wheels to version control (via git-lfs or sparse checkout)
git add offline/wheels/
git commit -m "Update Python wheels"

# 4. Rebuild images:
./docker/scripts/build-offline.sh --ver v2.0
```

### Kubernetes Manifests

For Kubernetes deployment, create manifests that reference local images:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: vm-migrator-backend
spec:
  containers:
  - name: backend
    image: vm-migrator/backend:v1.0
    imagePullPolicy: Never  # Explicitly don't pull from registry
    env:
    - name: DATABASE_URL
      value: "mysql://vm_user:admin@db-service:3306/vm_migrator"
```

## Best Practices

1. **Version Everything**: Tag all images with version numbers for traceability
2. **Verify Offline Resources Before Build**: Run `./docker/scripts/build-offline.sh --check`
3. **Test on Non-Production First**: Deploy to staging air-gapped cluster first
4. **Document Network Requirements**: Ensure all cluster networking policies are documented
5. **Use Image Registry**: For large clusters, use a private container registry inside the cluster
6. **Monitor Disk Usage**: Air-gapped images are large; ensure adequate cluster storage
7. **Keep Offline Cache Current**: Regularly update wheels and dependencies for security patches

## Support & Debugging

### Collect Logs

```bash
# Backend logs
docker-compose -f docker-compose.offline.yml logs backend > backend.log

# Worker logs
docker-compose -f docker-compose.offline.yml logs celery-worker > worker.log

# All services
docker-compose -f docker-compose.offline.yml logs > all-services.log
```

### Container Inspection

```bash
# Get shell access to container:
docker-compose -f docker-compose.offline.yml exec backend bash

# Check installed packages:
docker run --rm vm-migrator/backend:v1.0 pip list

# Verify VDDK:
docker run --rm vm-migrator/conversion-worker:v1.0 ls -la /opt/vmware-vddk/
```

---

**Last Updated**: May 2026  
**Docker Compose Version**: 3.8+  
**Tested On**: Debian Bookworm, Ubuntu 22.04+
