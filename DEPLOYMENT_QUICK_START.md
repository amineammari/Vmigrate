# VM Migrator: Docker Deployment Quick Start Guide

Complete step-by-step instructions to launch the vm-migrator application on a new VM.

## Prerequisites

### 1. Install Docker & Docker Compose
Run on the new VM:

```bash
# Update system
sudo apt-get update && sudo apt-get upgrade -y

# Install Docker
curl -fsSL https://get.docker.com -o get-docker.sh
sudo sh get-docker.sh

# Install Docker Compose (v2+)
sudo apt-get install -y docker-compose

# Add current user to docker group (optional, avoids sudo)
sudo usermod -aG docker $USER
newgrp docker

# Verify installation
docker --version
docker compose version
```

### 2. System Requirements
- **CPU**: 4+ cores recommended
- **RAM**: 8 GB+ (16 GB for real conversions)
- **Disk**: 100+ GB free (conversion work is disk-intensive)
- **Network**: Connected to ESXi host and OpenStack (if using real endpoints)

---

## Deployment Steps

### Step 1: Get Project Files

**Option A: Clone from Git**
```bash
git clone <your-repo-url> /opt/vm-migrator
cd /opt/vm-migrator
```

**Option B: Copy from Existing Machine**
```bash
# On source machine:
scp -r /home/amin/Desktop/vm-migrator user@new-vm:/opt/

# On new VM:
cd /opt/vm-migrator
```

### Step 2: Create Environment Configuration

Copy the example .env file and customize:

```bash
cd /opt/vm-migrator

# Create .env from template (if available)
cp .env.example .env || cp .env.template .env

# Or create a minimal .env:
cat > .env << 'EOF'
# Database
DB_ROOT_PASSWORD=rootpassword
DB_NAME=vm_migrator
DB_USER=vm_user
DB_PASSWORD=admin
DB_PUBLISHED_PORT=13306

# Redis
REDIS_PUBLISHED_PORT=16379

# Frontend
FRONTEND_PUBLISHED_PORT=80

# Backend
BACKEND_PUBLISHED_PORT=8000

# Docker Images
VM_MIGRATOR_VERSION=latest
VM_MIGRATOR_BACKEND_IMAGE=vm-migrator/backend
VM_MIGRATOR_CONVERSION_WORKER_IMAGE=vm-migrator/conversion-worker
VM_MIGRATOR_FRONTEND_IMAGE=vm-migrator/frontend

# Conversion Settings
ENABLE_REAL_CONVERSION=true
ENABLE_ANSIBLE_CONVERSION=true
ENABLE_TERRAFORM_FROM_CELERY=true

# VDDK / ESXi (if using VDDK transport)
VMWARE_ESXI_CONVERSION_TRANSPORT=vddk
VMWARE_VDDK_LIBDIR=/opt/vmware-vddk
VMWARE_VDDK_NBDKIT_PLUGIN_PATH=/usr/lib/x86_64-linux-gnu/nbdkit/plugins
VMWARE_NBDKIT_FILTER_PATH=/usr/lib/x86_64-linux-gnu/nbdkit/filters

# Libguestfs
LIBGUESTFS_BACKEND=direct
LIBGUESTFS_MEMSIZE=2048

# Terraform
TERRAFORM_VERSION=1.7.5
EOF
```

### Step 3: Create Docker Volumes & Directories

```bash
# Create required host directories
sudo mkdir -p /var/lib/vm-migrator/images
sudo mkdir -p /var/lib/vm-migrator/beat
sudo mkdir -p /var/log/vm-migrator

# Set permissions (if not using root)
sudo chown -R $USER:$USER /var/lib/vm-migrator
sudo chown -R $USER:$USER /var/log/vm-migrator
sudo chmod -R 755 /var/lib/vm-migrator
```

### Step 4: Start Containers

#### **Option A: Online Deployment** (Build from Source)

```bash
cd /opt/vm-migrator

# Build images locally
docker compose build

# Start services
docker compose up -d

# Monitor startup (wait 30-60 seconds for all services to be healthy)
docker compose logs -f
```

#### **Option B: Offline Deployment** (Use Pre-built Images)

**Step B.1: Prepare VDDK Runtime** (if using VDDK transport)

```bash
# If VDDK is available locally, copy to offline directory
mkdir -p offline/vendor/vddk
cp -r /opt/vmware-vddk/lib64 offline/vendor/vddk/

# If nbdkit plugin is available
mkdir -p offline/vendor
cp /path/to/nbdkit-vddk-plugin.so offline/vendor/
```

**Step B.2: Use Offline Docker Compose**

```bash
cd /opt/vm-migrator

# Use the offline-specific compose file (if building offline images)
docker compose -f docker-compose.offline.yml up -d

# Or if images are pre-built/pre-loaded:
docker compose up -d
```

**Step B.3: Load Pre-built Images from Tarball**

If you have a pre-exported image tarball (e.g., from another VM):

```bash
# Transfer the tarball
scp user@source-vm:/tmp/vm-migrator-images.tar.gz /tmp/

# Load images
gunzip < /tmp/vm-migrator-images.tar.gz | docker load

# Verify images loaded
docker images | grep vm-migrator

# Start containers
docker compose up -d
```

### Step 5: Verify Containers are Running

```bash
# Check all services
docker compose ps

# Expected output:
# NAME                           IMAGE                              STATUS
# vmigrate-db                    mariadb:10.11.8                    Up ... (healthy)
# vmigrate-redis                 redis:7.2.5-alpine                 Up ... (healthy)
# vmigrate-backend               vm-migrator/backend:latest         Up ... (healthy)
# vmigrate-worker                vm-migrator/conversion-worker:..   Up ...
# vmigrate-beat                  vm-migrator/backend:latest         Up ...
# vmigrate-frontend              vm-migrator/frontend:latest        Up ... (healthy)
```

### Step 6: Verify Services are Responding

```bash
# Check backend API
curl -s http://localhost:8000/api/health | jq .

# Check frontend
curl -s http://localhost/ | head -20

# Check logs for errors
docker compose logs backend | grep -i error
docker compose logs worker | grep -i error
```

### Step 7: Access the Application

Open a web browser:

```
http://<new-vm-ip>:80/
```

Default credentials: Check backend initialization logs or `.env` for superuser setup:
```bash
docker compose logs backend | grep -i "superadmin\|admin\|password"
```

---

## Configuration for Real Conversions

### ESXi / VDDK Setup

Edit `.env` with ESXi details:

```bash
# If ESXi is not resolvable via DNS, add to extra_hosts in docker-compose.yml:
# extra_hosts:
#   - "esxi.local:<esxi-ip>"
```

Update `docker-compose.yml` worker service:

```yaml
worker:
  extra_hosts:
    - "vmware.local:192.168.72.242"  # Change to your ESXi IP
```

### OpenStack Deployment

If using OpenStack for destination:

```bash
# Update settings in backend container
docker exec vmigrate-backend python3 manage.py shell <<EOF
from django.conf import settings
settings.OPENSTACK_ENDPOINT = "http://your-openstack:5000/v3"
settings.OPENSTACK_USER = "your_user"
# ... configure as needed
EOF
```

---

## Common Management Commands

```bash
# View all logs
docker compose logs -f

# View specific service logs
docker compose logs -f backend
docker compose logs -f worker

# Stop all containers
docker compose stop

# Start all containers
docker compose start

# Restart services
docker compose restart <service-name>
# Example: docker compose restart backend

# Remove all containers (keeps volumes)
docker compose down

# Remove all containers and volumes (DESTRUCTIVE)
docker compose down -v

# Check service health
docker compose exec backend /usr/local/bin/backend-healthcheck
docker compose exec worker celery -A core inspect active

# View database
docker compose exec db mariadb -u vm_user -padmin -D vm_migrator

# View Redis
docker compose exec redis redis-cli
```

---

## Troubleshooting

### Services Failed to Start

**Check logs:**
```bash
docker compose logs

# Or specific service:
docker compose logs backend
```

**Common issues:**
- Port conflicts: Change `*_PUBLISHED_PORT` in `.env`
- Disk space: Check `/var/lib/docker` and `/var/lib/vm-migrator`
- Memory: System needs 8+ GB RAM

### Backend Container Unhealthy

```bash
# Check database connection
docker compose exec backend python3 manage.py dbshell

# Check Redis connection
docker compose exec backend python3 manage.py shell <<EOF
import redis
r = redis.from_url("redis://redis:6379/0")
print(r.ping())
EOF
```

### Worker Container Not Picking Up Tasks

```bash
# Check Celery workers
docker compose exec worker celery -A core inspect active

# Check task queue
docker compose exec redis redis-cli LLEN migrations

# Restart worker
docker compose restart worker
```

### ESXi Discovery Not Working

```bash
# Test network connectivity from worker
docker compose exec worker ping 192.168.72.242

# Test ESXi VM discovery manually
docker compose exec worker python3 - <<EOF
import os
os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'core.settings')
import django
django.setup()
from migrations.openstack_client import VMwareClient
client = VMwareClient(host="192.168.72.242", user="root", password="...")
print(client.list_vms())
EOF
```

### VDDK/nbdkit Plugin Not Found

```bash
# Verify plugin in worker container
docker compose exec worker ls -la /usr/lib/x86_64-linux-gnu/nbdkit/plugins/nbdkit-vddk-plugin.so

# Test nbdkit plugin directly
docker compose exec worker nbdkit --dump-plugin vddk

# Check VDDK libdir
docker compose exec worker ls -la /opt/vmware-vddk/lib64/
```

---

## Backup & Disaster Recovery

### Backup Database

```bash
docker compose exec db mariadb-dump -u vm_user -padmin vm_migrator > /backup/vm_migrator_db.sql
```

### Backup Conversion History

```bash
sudo tar -czf /backup/vm_migrator_images.tar.gz /var/lib/vm-migrator/images/
```

### Restore Database

```bash
docker compose exec db mariadb -u vm_user -padmin vm_migrator < /backup/vm_migrator_db.sql
```

---

## Production Checklist

- [ ] Change default database password in `.env`
- [ ] Change default Redis password (if needed)
- [ ] Configure SSL/TLS for frontend (nginx.conf)
- [ ] Set up log rotation for container logs
- [ ] Configure backup strategy for `/var/lib/vm-migrator`
- [ ] Set proper resource limits in docker-compose.yml
- [ ] Test ESXi/OpenStack connectivity before running migrations
- [ ] Set up monitoring/alerts for container health

---

## Next Steps

1. **Create first migration session**: Use UI to add ESXi credentials → Discover VMs → Create migration job
2. **Monitor jobs**: Watch logs in real-time with `docker compose logs -f worker`
3. **Review conversion outputs**: Check `/var/lib/vm-migrator/images/` for QCOW2/VMDK outputs

For detailed operational docs, see [DOCKER_SETUP.md](./DOCKER_SETUP.md) and [PRODUCTION_AUTH_SESSION_WORKER_GUIDE.md](./PRODUCTION_AUTH_SESSION_WORKER_GUIDE.md).
