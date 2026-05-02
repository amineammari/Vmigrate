# VMigrate Docker Setup - Complete Fix Summary

## 1. Updated/Created Files

### docker-compose.yml
- Fixed database from PostgreSQL to MariaDB (matching .env configuration)
- Added proper healthchecks with `service_healthy` dependency conditions
- Added `beat` service for Celery periodic tasks
- Fixed worker network configuration (was missing)
- Added volumes for ansible and terraform directories
- Removed obsolete `version` attribute
- Added MariaDB environment variables from .env

### Dockerfile (Multi-stage build)
- **Backend stage**: Python 3.11-slim, installs dependencies, copies backend code
- **Worker stage**: Adds qemu-utils, libguestfs-tools, virt-v2v, nbdkit, ansible, terraform
- **Frontend stage**: Node 20 build → Nginx serve with custom nginx.conf
- Fixed mysqlclient build dependencies (default-libmysqlclient-dev, pkg-config)

### backend/core/settings.py
- Updated `ALLOWED_HOSTS` to include Docker service names (backend, db, redis, etc.)

### backend/core/urls.py
- Added health endpoint at `/api/health` for container healthcheck

### .env (root)
- Fixed `DATABASE_URL` to use `db` service name instead of localhost
- Fixed `REDIS_URL` to use `redis` service name
- Updated paths to use `/app/` prefix for container paths
- Added DB_ROOT_PASSWORD, DB_NAME, DB_USER, DB_PASSWORD for MariaDB container
- Updated VMware VDDK/NBDKIT paths to system locations in container

### .env.example (root)
- Created comprehensive example with all required variables
- No secrets, safe for version control

### frontend/.env
- Updated `VITE_API_BASE_URL` to use `http://backend:8000`
- Updated `VITE_PROXY_TARGET` to use `http://backend:8000`

### frontend/nginx.conf
- Created nginx configuration to serve frontend and proxy `/api` requests to backend

### backend/requirements.txt
- Created from pip freeze output (all dependencies captured)

### entrypoint.sh
- Existing entrypoint is correct (migrate + collectstatic + exec)

---

## 2. Detected Tools & Handling

| Tool | Status | Handling |
|------|--------|-----------|
| **Django 4.2** | ✅ Required | Backend service with Gunicorn |
| **Django REST Framework** | ✅ Required | API layer |
| **Celery 5.6** | ✅ Required | Worker + Beat services |
| **Redis 7** | ✅ Required | Broker & result backend |
| **MariaDB 10.6** | ✅ Required | Database (changed from PostgreSQL) |
| **React + Vite** | ✅ Required | Frontend with Nginx |
| **VMware pyvmomi** | ✅ Integration | VMware discovery & migration |
| **OpenStack SDK** | ✅ Integration | OpenStack provisioning |
| **virt-v2v** | ✅ Worker tool | Disk conversion (installed in worker) |
| **qemu-utils** | ✅ Worker tool | QCOW2 conversion |
| **libguestfs-tools** | ✅ Worker tool | Guest filesystem inspection |
| **nbdkit** | ✅ Worker tool | NBD access for VMware disks |
| **Ansible** | ✅ Optional | Playbook-based conversion (disabled by default) |
| **Terraform** | ✅ Optional | Infrastructure provisioning (enabled) |
| **mysqlclient** | ✅ Required | MariaDB adapter for Django |
| **django-cryptography** | ✅ Required | Encrypted fields for credentials |
| **django-environ** | ✅ Required | Environment variable handling |
| **django-simplejwt** | ✅ Required | JWT authentication |

---

## 3. List of Fixes Applied

### Critical Fixes
1. **Database mismatch**: docker-compose used PostgreSQL, .env used MySQL → Fixed to MariaDB
2. **Missing requirements.txt**: Created from actual dependencies in .venv
3. **Missing Celery Beat**: Added `beat` service for periodic discovery
4. **Worker missing networks**: Added `vmigrate-net` network to worker service
5. **Healthcheck issues**: 
   - Backend healthcheck used `curl` (not in container) → Changed to Python urllib
   - MariaDB healthcheck fixed with proper credentials variable
   - Added `start_period` for services that need boot time

### Docker Configuration Fixes
6. **Localhost references**: Replaced all `127.0.0.1`/`localhost` with Docker service names
7. **Path fixes**: Updated .env paths to use `/app/` prefix for containers
8. **Frontend proxy**: Created nginx.conf to proxy API requests to backend
9. **Frontend .env**: Fixed `VITE_PROXY_TARGET` to use `http://backend:8000`
10. **ALLOWED_HOSTS**: Added Docker service names for proper request handling

### Worker Tools Fixes
11. **virt-v2v**: Added to worker Dockerfile (was missing)
12. **nbdkit**: Added to worker Dockerfile
13. **libguestfs-tools**: Added to worker Dockerfile
14. **Ansible**: Added to worker Dockerfile
15. **Terraform**: Already present, verified

### Volume Mounts
16. **Added ansible mount**: `/app/ansible:ro` for worker
17. **Added terraform mount**: `/app/terraform:ro` for worker
18. **Fixed static files**: Changed to `/app/staticfiles` to match Django settings

---

## 4. Step-by-Step Commands to Run

### Prerequisites
```bash
# Ensure Docker and Docker Compose are installed
docker --version
docker compose version
```

### Step 1: Clone and Setup
```bash
cd /home/amin/Desktop/vm-migrator
```

### Step 2: Configure Environment
```bash
# The .env file is already configured
# Review and update OpenStack/VMware credentials as needed:
nano .env
```

### Step 3: Build and Start Services
```bash
# Build all images (first time or after changes)
docker compose build

# Start all services
docker compose up -d

# View logs
docker compose logs -f

# Or start with logs visible
docker compose up
```

### Step 4: Verify Services
```bash
# Check service status
docker compose ps

# Test backend health
curl http://localhost:8000/api/health

# Test frontend
curl http://localhost/

# Check specific service logs
docker compose logs backend
docker compose logs worker
docker compose logs frontend
docker compose logs db
docker compose logs redis
```

### Step 5: Access the Application
- **Frontend**: http://localhost
- **Backend API**: http://localhost:8000/api/
- **Admin**: http://localhost:8000/admin/

### Common Commands
```bash
# Stop all services
docker compose down

# Rebuild after code changes
docker compose up --build -d

# Run migrations manually (if needed)
docker compose exec backend python manage.py migrate

# Create superuser
docker compose exec backend python manage.py createsuperuser

# Shell into backend
docker compose exec backend bash

# Restart a specific service
docker compose restart worker
```

---

## 5. Architecture Verification

### Service Communication
```
Frontend (port 80) → Backend (port 8000) → [Redis, MariaDB]
                                    ↓
                              Worker + Beat
                                    ↓
                         [Ansible, Terraform, virt-v2v]
```

### Networks
- All services on `vmigrate-net` bridge network
- Service discovery via Docker DNS (service names)

### Volumes
- `mariadb-data`: Persistent MariaDB storage
- `images`: Shared migration artifacts between backend/worker
- `./backend/logs`: Application logs

---

## 6. Notes

1. **First run** will take time to build images and run migrations
2. **Worker** has heavy tools installed (virt-v2v, libguestfs, etc.) - image will be larger
3. **OpenStack/VMware credentials** must be configured in `.env` for actual migrations
4. **Ansible conversion** is disabled by default (`ENABLE_ANSIBLE_CONVERSION=false`)
5. **Terraform** is enabled (`ENABLE_TERRAFORM_INFRA=true`)
6. For production, set `DEBUG=false` and generate a proper `SECRET_KEY`

---

## 7. Troubleshooting

### Database connection issues
```bash
docker compose logs db
docker compose exec db mariadb -u vm_user -padmin vm_migrator
```

### Redis connection issues
```bash
docker compose exec redis redis-cli ping
```

### Worker can't find tools
```bash
docker compose exec worker which virt-v2v
docker compose exec worker which terraform
```

### Backend migration issues
```bash
docker compose exec backend python manage.py showmigrations
docker compose exec backend python manage.py migrate --verbosity 3
```
