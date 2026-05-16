# VM-Migrator: Complete Offline Deployment Implementation Guide

**Document Version**: 1.0  
**Date**: 2026-05-13  
**Purpose**: Step-by-step implementation of fully air-gapped deployment

---

## Table of Contents

1. [Quick Start (5 minutes)](#quick-start)
2. [Phase 1: Prepare Online System](#phase-1-prepare-online-system)
3. [Phase 2: Offline Build & Validation](#phase-2-offline-build--validation)
4. [Phase 3: Deploy to Target System](#phase-3-deploy-to-target-system)
5. [Phase 4: Post-Deployment Validation](#phase-4-post-deployment-validation)
6. [Troubleshooting](#troubleshooting)
7. [Advanced Scenarios](#advanced-scenarios)

---

## Quick Start

**For experienced users who understand air-gapped deployment?**

```bash
# On ONLINE system (has internet):
cd vm-migrator
pip wheel -r backend/requirements.txt -w offline/wheels/
cd frontend && npm install && npm ci
cd ..
terraform providers mirror offline/terraform-providers/
docker pull mariadb:10.11.8 redis:7.2.5-alpine python:3.11.9-slim-bookworm node:20-alpine
docker save ... -o offline/images/base-images.tar

# Transfer all of offline/* to target system via USB/SCP/etc.

# On OFFLINE system:
docker load < offline/images/base-images.tar
./docker/scripts/build-offline-enhanced.sh
docker-compose -f docker-compose.offline.yml up -d
./scripts/validate-offline-deployment.sh
```

---

## Phase 1: Prepare Online System

**Duration**: 20-30 minutes  
**Requirements**: Internet connectivity, Docker, Python 3.8+, Node 18+

### Step 1.1: Validate Online System

```bash
cd ~/vm-migrator

# Check prerequisites
python3 --version  # Should be 3.8 or higher
pip --version
npm --version
node --version
docker --version
terraform --version
git --version
```

### Step 1.2: Clone/Update Repository

```bash
# If not already cloned:
git clone <vm-migrator-repo> && cd vm-migrator

# Or update existing:
git pull origin main
```

### Step 1.3: Create Offline Directories

```bash
mkdir -p offline/{wheels,npm-cache,terraform-providers,vendor/vddk,images}
cd offline && ls -la
```

**Expected output**:
```
drwxr-xr-x  2 user  group  4096  May 13 12:00 wheels/
drwxr-xr-x  2 user  group  4096  May 13 12:00 npm-cache/
drwxr-xr-x  2 user  group  4096  May 13 12:00 terraform-providers/
drwxr-xr-x  3 user  group  4096  May 13 12:00 vendor/
drwxr-xr-x  2 user  group  4096  May 13 12:00 images/
```

### Step 1.4: Download Python Wheels

```bash
cd ~/vm-migrator

# Generate all wheels from requirements.txt
pip wheel -r backend/requirements.txt --no-cache-dir -w offline/wheels/

# Verify wheels count
find offline/wheels -name "*.whl" | wc -l  # Should be 75+

# List critical packages
ls -lh offline/wheels/ | grep -E "Django|celery|redis|mysql"
```

**Expected**:
```
-rw-r--r-- 1 user group  8.5M Django-4.2.16-py3-none-any.whl
-rw-r--r-- 1 user group  2.3M celery-5.6.2-py3-none-any.whl
-rw-r--r-- 1 user group  1.2M redis-7.1.1-py3-none-any.whl
-rw-r--r-- 1 user group  2.1M mysqlclient-2.2.8-cp311-...whl
```

### Step 1.5: Cache Frontend Dependencies

```bash
cd ~/vm-migrator/frontend

# Install npm dependencies
npm install

# Verify package-lock.json
test -f package-lock.json && echo "✓ package-lock.json present"

# Cache npm modules
npm cache verify

echo "Cache location:"
npm config get cache  # e.g., ~/.npm
```

**Expected**:
```
added 150 packages in 25s
npm notice...
Cache verified successfully
/home/user/.npm
```

### Step 1.6: Pre-Download Terraform Plugins

```bash
cd ~/vm-migrator

# Generate terraform plugin mirror
terraform providers mirror offline/terraform-providers/

# Verify plugins are cached
find offline/terraform-providers -name "*.zip" | wc -l
```

**Expected output**: 
```
Terraform plugin mirror directory is ready
/home/user/vm-migrator/offline/terraform-providers/

Downloaded providers:
  registry.terraform.io/hashicorp/local
  registry.terraform.io/hashicorp/null
  registry.terraform.io/hashicorp/openstack
  (and others)
```

### Step 1.7: Pre-Load Base Docker Images

```bash
cd ~/vm-migrator/offline/images

# Pull all base images
docker pull python:3.11.9-slim-bookworm
docker pull node:20-alpine
docker pull mariadb:10.11.8
docker pull redis:7.2.5-alpine

# Export to tar file (single file for easy transfer)
docker save \
  python:3.11.9-slim-bookworm \
  node:20-alpine \
  mariadb:10.11.8 \
  redis:7.2.5-alpine \
  -o base-images.tar

# Verify size
ls -lh base-images.tar  # Will be ~1.5-2GB

# Compress for transfer if needed
gzip -c base-images.tar > base-images.tar.gz
ls -lh base-images.tar.gz
```

### Step 1.8: Optional - Obtain VDDK SDK

⚠️ **REQUIRES VMware LICENSE AGREEMENT**

```bash
cd ~/vm-migrator/offline/vendor

# Download from: https://developer.vmware.com/web/sdk/vddk
# Extract: tar -xzf VMware-vddk-8.0.0-xxxx.tar.gz -C vddk/

# Verify extraction
ls -la vddk/
ls -la vddk/lib64/libvixDiskLib.so*  # Should show .so files

# Check nbdkit plugin
find vddk -name "*nbdkit*.so" -o -name "*nbdkit*.a"
```

---

## Phase 2: Create Offline Bundle

**Duration**: 5-10 minutes

### Step 2.1: Generate Artifact Manifest

```bash
cd ~/vm-migrator

# Create comprehensive dependency manifest
bash scripts/validate-offline-artifacts.sh

# This generates:
# - offline/ARTIFACT_MANIFEST.json (all dependencies listed)
# - offline/.artifacts.sha256 (integrity checksums)
```

**Expected output**:
```
[✓] Found 75 Python wheel files
[✓] NPM cache size: 206M
[✓] Found 12 Terraform provider files
[⚠] VDDK optional (not present)
[✓] All base Docker images loaded

Manifest generated: offline/ARTIFACT_MANIFEST.json
Checksums saved: offline/.artifacts.sha256
```

### Step 2.2: Create Portable Bundle

```bash
cd ~/vm-migrator

# Create compressed bundle for transfer (all offline artifacts)
tar -czf vm-migrator-offline-bundle-$(date +%Y%m%d).tar.gz \
  offline/ \
  docker/ \
  backend/ \
  frontend/ \
  ansible/ \
  terraform/ \
  .env \
  docker-compose.offline.yml \
  scripts/validate-offline-artifacts.sh \
  scripts/validate-offline-deployment.sh

# Check size
ls -lh vm-migrator-offline-bundle-*.tar.gz

# Verify contents
tar -tzf vm-migrator-offline-bundle-*.tar.gz | head -20
```

**Expected size**: 2-4GB (depending on wheel sizes)

---

## Phase 3: Transfer to Offline System

**Duration**: Variable (depends on transfer method)

### Step 3.1: Transfer Method Options

#### Option A: USB Drive
```bash
# On online system:
cp vm-migrator-offline-bundle-*.tar.gz /media/usb/

# On offline system:
cp /media/usb/vm-migrator-offline-bundle-*.tar.gz ~/
tar -xzf vm-migrator-offline-bundle-*.tar.gz
```

#### Option B: Secure Copy (SCP) - If network available
```bash
# From online system to offline system:
scp vm-migrator-offline-bundle-*.tar.gz user@offline-target:/home/user/

# On offline target:
cd /home/user
tar -xzf vm-migrator-offline-bundle-*.tar.gz
```

#### Option C: Docker Registry Transfer
```bash
# On online system:
docker save \
  vm-migrator/backend:offline \
  vm-migrator/frontend:offline \
  vm-migrator/conversion-worker:offline \
  -o custom-images.tar

# Transfer custom-images.tar along with base-images.tar to offline system
```

### Step 3.2: Verify Transfer Integrity

```bash
cd ~/vm-migrator

# Verify checksums
sha256sum -c offline/.artifacts.sha256

# Expected:
# wheels/Django-4.2.16-py3-none-any.whl: OK
# wheels/celery-5.6.2-py3-none-any.whl: OK
# ... (all files checked)
```

**If any file fails checksum**, re-transfer that file.

---

## Phase 4: Offline Build & Validation

**Duration**: 15-20 minutes  
**Requirements**: No internet needed

### Step 4.1: Load Base Docker Images

```bash
# On offline system:
cd ~/vm-migrator

# Load base images from tarball
docker load < offline/images/base-images.tar

# Verify all images loaded
docker images | grep -E "python:3.11|node:20|mariadb:10|redis:7"
```

**Expected**:
```
REPOSITORY                   TAG                    SIZE
python                       3.11.9-slim-bookworm   361MB
node                         20-alpine              168MB
mariadb                      10.11.8                380MB
redis                        7.2.5-alpine           42MB
```

### Step 4.2: Pre-Flight Validation

```bash
cd ~/vm-migrator

# Run comprehensive artifact validation
bash scripts/validate-offline-artifacts.sh

# Inspect output for any warnings/errors
# Address critical failures before building
```

### Step 4.3: Build Docker Images

```bash
cd ~/vm-migrator

# Make build script executable
chmod +x docker/scripts/build-offline-enhanced.sh

# Run enhanced build (validates artifacts first)
./docker/scripts/build-offline-enhanced.sh

# Or with specific options:
./docker/scripts/build-offline-enhanced.sh --no-cache --version 1.0

# Build time: ~10-15 minutes (machine-dependent)
```

**Expected output**:
```
[✓] All requirements met
[✓] Found 75 Python wheel files
[✓] NPN cache size: 206M
[✓] Docker image present: python:3.11.9-slim-bookworm
===== Building Backend Image =====
[✓] Backend image built successfully

===== Building Conversion Worker Image =====
[✓] Conversion worker image built successfully

===== Building Frontend Image =====
[✓] Frontend image built successfully

Image Summary:
REPOSITORY                  TAG         SIZE
vm-migrator/backend         offline     1.27GB
vm-migrator/conversion-worker offline   2.01GB
vm-migrator/frontend        offline     208MB
```

### Step 4.4: Resource Check

```bash
cd ~/vm-migrator

# Check available disk space
df -h .

# Check Docker storage usage
docker system df

# Expected: ~50GB available after build
```

---

## Phase 5: Deploy to Target System

**Duration**: 5 minutes

### Step 5.1: Configure Environment

```bash
cd ~/vm-migrator

# Copy or create .env file
test -f .env || cat > .env << 'EOF'
# Database
DB_ROOT_PASSWORD=secure-root-password-change-me
DB_NAME=vm_migrator
DB_USER=vm_user
DB_PASSWORD=secure-db-password-change-me
DB_PUBLISHED_PORT=13306

# Redis
REDIS_PUBLISHED_PORT=16379

# Django
SECRET_KEY=change-this-to-random-value-at-least-50-chars
DEBUG=false
ALLOWED_HOSTS=localhost,127.0.0.1,backend,vmigrate-backend

# Backend
BACKEND_PUBLISHED_PORT=8000
VM_MIGRATOR_BACKEND_IMAGE=vm-migrator/backend
VM_MIGRATOR_FRONTEND_IMAGE=vm-migrator/frontend
VM_MIGRATOR_WORKER_IMAGE=vm-migrator/conversion-worker
VM_MIGRATOR_VERSION=offline

# Optional: Cloud endpoints (leave blank for local-only mode)
# OS_AUTH_URL=http://openstack:5000/v3
# VMWARE_ESXI_HOST=esxi.example.com

# Disable preflight checks if VDDK/terraform not available
# SKIP_CONVERSION_PREFLIGHT=true
EOF

# Verify .env
test -f .env && echo "✓ .env configured"
```

### Step 5.2: Create Docker Network (if needed)

```bash
# Docker Compose usually creates network automatically, but verify:
docker network create control-plane-offline 2>/dev/null || echo "Network already exists"

# Verify network
docker network inspect control-plane-offline
```

### Step 5.3: Deploy Services

```bash
cd ~/vm-migrator

# Bring up all services in detached mode
docker-compose -f docker-compose.offline.yml up -d

# Wait for containers to start (~20 seconds for healthchecks)
echo "Waiting for containers to start..."
sleep 30

# Check status
docker-compose -f docker-compose.offline.yml ps
```

**Expected output**:
```
NAME                       STATUS                      PORTS
vmigrate-db-offline        Up 25s (healthy)            0.0.0.0:13306->3306/tcp
vmigrate-redis-offline     Up 25s (healthy)            0.0.0.0:16379->6379/tcp
vmigrate-backend-offline   Up 20s (healthy)            0.0.0.0:8000->8000/tcp
vmigrate-frontend-offline  Up 19s (healthy)            0.0.0.0:3000->3000/tcp
vmigrate-celery-beat-offline Up 18s (healthy)
vmigrate-conversion-worker-offline Up 15s (health: starting)
```

### Step 5.4: View Logs

```bash
# Follow backend logs
docker-compose -f docker-compose.offline.yml logs -f backend

# Or just the last 50 lines
docker-compose logs -n 50 backend
```

**Expected logs** (backend starts):
```
[uWSGI] spawning worker 1
[uWSGI] spawning worker 2
[uWSGI] spawning worker 3
[uWSGI] master process ready
Starting gunicorn 21.2.0
Listening at: 0.0.0.0:8000
```

---

## Phase 6: Post-Deployment Validation

**Duration**: 5 minutes

### Step 6.1: Run Comprehensive Validation

```bash
cd ~/vm-migrator

# Make validator script executable
chmod +x scripts/validate-offline-deployment.sh

# Run all tests
./scripts/validate-offline-deployment.sh

# Run with verbose output for debugging
./scripts/validate-offline-deployment.sh --verbose
```

**Expected output** (all passing):
```
[PASS] Docker daemon is running
[PASS] Container exists: vmigrate-db-offline
[PASS] Container running: vmigrate-backend-offline
[PASS] Container healthy: vmigrate-backend-offline
[PASS] Backend health endpoint responds
[PASS] Frontend serves HTTP 200
[PASS] Database responds to ping
[PASS] Redis responds to ping
[PASS] No default route detected (air-gapped)
[PASS] Sufficient disk space: 45GB available

======== Final Report ========
Tests Passed: 15/15 (100%)
✓ All tests passed! Deployment is healthy.
```

### Step 6.2: Manual API Tests

```bash
# Test backend health
curl http://localhost:8000/api/health

# Expected:
# {"status":"ok"}

# Test frontend
curl http://localhost:3000/

# Expected: HTML content (React SPA)

# Test database
docker exec vmigrate-db-offline mysql -u root -p"$DB_ROOT_PASSWORD" -e "SELECT VERSION();"

# Expected: MariaDB version string

# Test redis
docker exec vmigrate-redis-offline redis-cli PING

# Expected: PONG
```

### Step 6.3: Check Storage

```bash
# View used space
docker system df

# View volume usage
docker volume ls
du -sh /var/lib/docker/volumes/*offline*/

# Expected: Database volume ~100-500MB, others 10-50MB (initially)
```

---

## Troubleshooting

### Problem: Base image pull fails during build

**Symptom**:
```
ERROR: failed to solve with frontend dockerfile.v0: failed to resolve image "python:3.11.9-slim-bookworm"
```

**Solution**:
```bash
# Ensure base images are pre-loaded
docker load < offline/images/base-images.tar
docker images  # Verify all 4 base images present

# Retry build
./docker/scripts/build-offline-enhanced.sh
```

---

### Problem: Python wheels not found

**Symptom**:
```
ERROR: Could not find a version that satisfies the requirement Django==4.2.16
```

**Solution**:
```bash
# Check wheels directory
ls -la offline/wheels/ | wc -l  # Should be 75+

# If empty, regenerate on online system
pip wheel -r backend/requirements.txt -w offline/wheels/

# Re-transfer to offline system
```

---

### Problem: Frontend build fails (npm issues)

**Symptom**:
```
npm ERR! 404 Not Found
npm ERR! code E404
```

**Solution**:
```bash
# Use offline npm CI with package-lock
cd frontend
npm ci --prefer-offline --no-audit --cache=/root/.npm

# Or use existing node_modules
test -d node_modules && echo "Using existing node_modules"
npm run build
```

---

### Problem: Container unhealthy

**Symptom**:
```
vmigrate-backend-offline   Up 45s (unhealthy)
```

**Solution**:
```bash
# Check container logs
docker logs vmigrate-backend-offline | tail -50

# Common causes:
# 1. Database not ready
docker exec vmigrate-db-offline mysql -u root -p"$DB_ROOT_PASSWORD" -e "SELECT 1;"

# 2. Redis not ready
docker exec vmigrate-redis-offline redis-cli PING

# 3. Missing Python packages
docker exec vmigrate-backend-offline python -c "import django; print(django.__version__)"

# 4. Restart container
docker-compose -f docker-compose.offline.yml restart backend
```

---

### Problem: No internet connectivity confirmed

**Symptom**: 
```
[FAIL] External DNS/HTTP unreachable (air-gapped confirmed)
```

**This is GOOD** - confirms air-gapped deployment!

---

## Advanced Scenarios

### Scenario 1: Add Custom Python Package

```bash
# On online system:
pip download <package-name> -d offline/wheels/

# Transfer offline/wheels/ to target system

# Rebuild
./docker/scripts/build-offline-enhanced.sh --no-cache
```

---

### Scenario 2: Update Terraform Providers

```bash
# On online system:
cd offline/terraform-providers/
terraform providers mirror .  # Updates existing mirror

# Transfer updated mirror to target system
```

---

### Scenario 3: Deploy Custom Code Changes

```bash
# On online system (after code changes):
./docker/scripts/build-offline-enhanced.sh --version custom-v1

# Transfer updated docker images:
docker save vm-migrator/backend:custom-v1 -o offline/images/backend-custom.tar

# On target system:
docker load < offline/images/backend-custom.tar
docker-compose -f docker-compose.offline.yml up -d  # Pulls new image
```

---

### Scenario 4: Migration from Online to Offline

```bash
# On online system (running):
docker-compose exec db mysqldump -u root -p"$DB_ROOT_PASSWORD" vm_migrator > db-backup.sql

# Transfer to offline:
scp db-backup.sql user@offline:/tmp/

# On offline system:
docker-compose -f docker-compose.offline.yml exec db mysql -u root -p"$DB_ROOT_PASSWORD" vm_migrator < /tmp/db-backup.sql
```

---

## Summary Checklist

- [ ] Phase 1: Online system prepared (wheels, npm, terraform, base images)
- [ ] Phase 2: Offline bundle created with manifest + checksums
- [ ] Phase 3: Bundle transferred to offline system with verification
- [ ] Phase 4: Base images loaded, artifacts validated, custom images built
- [ ] Phase 5: docker-compose deployed, services started
- [ ] Phase 6: Validation tests 100% passing
- [ ] Phase 7: Manual API tests successful
- [ ] Phase 8: Backups created (if applicable)
- [ ] Phase 9: Monitoring configured (logs, alerting, etc.)

---

## Next Steps

1. **Monitor Logs**: `docker-compose logs -f`
2. **Scale Workers**: Adjust CELERY_WORKER_CONCURRENCY in .env
3. **Configure Cloud Endpoints**: Add OS_AUTH_URL/VMWARE_ESXI_HOST if needed
4. **Daily Validation**: `./scripts/validate-offline-deployment.sh` (cron job)
5. **Backup Database**: Regular `mysqldump` exports


## Support

For issues:
1. Check troubleshooting section above
2. Review container logs: `docker logs <container-name>`
3. Run validation with --verbose: `./scripts/validate-offline-deployment.sh --verbose`
4. Check OFFLINE_DEPLOYMENT_STRATEGY.md for architecture details

