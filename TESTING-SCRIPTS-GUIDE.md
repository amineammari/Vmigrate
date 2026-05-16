# VM Testing Scripts - Quick Reference Guide

Two complementary scripts for testing vm-migrator on a new VM.

## 📋 Overview

| Script | VM | Purpose | Duration |
|--------|----|----|----------|
| **source-vm-prepare.sh** | Build/Current | Package and transfer files to test VM | 10-15 min |
| **test-vm-deploy.sh** | Test VM | Extract, build, deploy, and test | 20-30 min |

---

## 🚀 Quick Start

### Step 1: Run on SOURCE VM (Current Machine)

```bash
cd /home/amin/Desktop/vm-migrator

# Make script executable
chmod +x source-vm-prepare.sh

# Run preparation script
./source-vm-prepare.sh
```

**What it does**:
- ✅ Packages all offline dependencies
- ✅ Creates compressed archive (~3-4 GB)
- ✅ Transfers to test VM via SCP
- ✅ Verifies transfer integrity
- ✅ Creates log file with checksums

**Output**: 
- Archive: `~/vm-migrator-offline-YYYYMMDD-HHMMSS.tar.gz`
- Checksum: `~/vm-migrator-offline-YYYYMMDD-HHMMSS.tar.gz.sha256`
- Log: `~/vm-migrator-offline-YYYYMMDD-HHMMSS-package.log`

### Step 2: Run on TEST VM (192.168.72.244)

The script is automatically transferred via SCP in step 1.

```bash
# SSH into test VM
ssh amin@192.168.72.244

# Navigate to deployment directory
cd ~/vm-migrator-deploy

# Make script executable
chmod +x test-vm-deploy.sh

# Run deployment script
./test-vm-deploy.sh
```

**What it does**:
- ✅ Verifies archive transfer
- ✅ Extracts deployment package
- ✅ Verifies Docker installation
- ✅ Builds Docker images from offline resources
- ✅ Deploys all services
- ✅ Initializes database
- ✅ Runs comprehensive test suite
- ✅ Generates test report

**Output**:
- Working Dir: `~/vm-migrator-test-YYYYMMDD-HHMMSS/`
- Deployment Log: `~/vm-migrator-test-YYYYMMDD-HHMMSS/deployment.log`
- Test Report: `~/vm-migrator-test-YYYYMMDD-HHMMSS/test-report.log`

---

## 📝 Script Details

### source-vm-prepare.sh

**Features**:
```
✓ Pre-flight checks (disk space, required files)
✓ Package creation with all dependencies
✓ Compressed archive creation
✓ Archive integrity verification
✓ SCP transfer to test VM
✓ Checksum calculation and transfer
✓ Detailed logging with timestamps
✓ Cleanup of temporary files
```

**Logs**:
- `~/vm-migrator-offline-*.log` - Complete operation log
- Shows: Checksums, transfer details, verification results

**Error Handling**:
- Validates all prerequisites before starting
- Checks disk space
- Verifies all required files exist
- Tests network connectivity to test VM
- Validates archive integrity

---

### test-vm-deploy.sh

**Features**:
```
✓ Archive verification and extraction
✓ Docker and Docker Compose validation
✓ Offline resources verification
✓ Environment configuration
✓ Docker image building with progress
✓ Service deployment and health checks
✓ Database initialization
✓ Comprehensive test suite (10 tests)
✓ Detailed test reporting
✓ Access information generation
```

**Tests Performed** (10 comprehensive tests):
1. **Service Health** - Verifies all 6 containers running
2. **Frontend** - Tests React UI accessibility
3. **Backend API** - Validates REST API health check
4. **Admin Panel** - Tests Django admin accessibility
5. **Database** - Verifies database connectivity
6. **Celery Worker** - Checks task queue worker
7. **Redis** - Validates cache service
8. **Offline Verification** - Confirms no external dependencies
9. **Logs** - Checks for critical errors
10. **Volume Mounts** - Validates storage configuration

**Reports**:
- `~/vm-migrator-test-*/deployment.log` - Full deployment details
- `~/vm-migrator-test-*/test-report.log` - Test results and access info

---

## 💻 Example Execution

### On Source VM

```bash
$ /home/amin/Desktop/vm-migrator/source-vm-prepare.sh

╔════════════════════════════════════════════════════════════════════════════╗
║                 SOURCE VM SCRIPT - PREPARE FOR TEST VM DEPLOYMENT         ║
║  This script will:                                                         ║
║    1. Package vm-migrator offline deployment files                         ║
║    2. Create compressed archive (~3-4 GB)                                  ║
║    3. Transfer to test VM via SCP                                          ║
║    4. Verify transfer integrity                                            ║
╚════════════════════════════════════════════════════════════════════════════╝

[INFO] 14:32:15 Starting vm-migrator source VM preparation...
[INFO] 14:32:15 Log file: /home/amin/vm-migrator-offline-20260511-143215-package.log

═══════════════════════════════════════════════════════════════════════════
CHECKING PREREQUISITES
═══════════════════════════════════════════════════════════════════════════

[INFO] 14:32:15 Project directory found: /home/amin/Desktop/vm-migrator
✓ Found: offline/wheels
✓ Found: offline/vendor/vddk
... (more files verified)

═══════════════════════════════════════════════════════════════════════════
CREATING PACKAGE
... (files being copied)

═══════════════════════════════════════════════════════════════════════════
CREATING ARCHIVE
→ Creating compressed archive: /home/amin/vm-migrator-offline-20260511-143215.tar.gz
... (takes 2-5 minutes)

═══════════════════════════════════════════════════════════════════════════
TRANSFERRING TO TEST VM
→ Transferring archive (~3.2 GB)
... (takes 5-10 minutes depending on network)

═══════════════════════════════════════════════════════════════════════════
SUMMARY
✓ PACKAGING COMPLETE

Package Details:
  Name: vm-migrator-offline-20260511-143215
  Archive: /home/amin/vm-migrator-offline-20260511-143215.tar.gz
  Size: 3.2G
  Checksum: a1b2c3d4e5f6...
  
Transfer Details:
  Destination: amin@192.168.72.244
  Remote Path: ~/vm-migrator-deploy/
```

### On Test VM

```bash
$ /home/amin/vm-migrator-deploy/test-vm-deploy.sh

╔════════════════════════════════════════════════════════════════════════════╗
║          TEST VM SCRIPT - DEPLOY & TEST VM-MIGRATOR OFFLINE               ║
║  This script will:                                                         ║
║    1. Extract deployment package from archive                              ║
║    2. Verify Docker and all prerequisites                                  ║
║    3. Build Docker images from offline dependencies                        ║
║    4. Deploy all services with docker-compose                              ║
║    5. Initialize database and static files                                 ║
║    6. Run comprehensive test suite                                         ║
║    7. Generate detailed test report                                        ║
║  Duration: ~20-30 minutes total                                            ║
╚════════════════════════════════════════════════════════════════════════════╝

[INFO] 14:42:30 Starting vm-migrator test VM deployment...

═══════════════════════════════════════════════════════════════════════════
VERIFYING TRANSFER
... (archive verified)

═══════════════════════════════════════════════════════════════════════════
EXTRACTING ARCHIVE
... (files extracted, ~30 seconds)

═══════════════════════════════════════════════════════════════════════════
BUILDING DOCKER IMAGES
→ This will take 10-15 minutes...
→ Watch progress in: tail -f deployment.log
... (images being built)

═══════════════════════════════════════════════════════════════════════════
DEPLOYING SERVICES
→ Starting Docker Compose stack...
✓ Services started

═══════════════════════════════════════════════════════════════════════════
RUNNING COMPREHENSIVE TESTS
[TEST] Service Health
✓ PASS - All 6 services running

[TEST] Frontend Service
✓ PASS - Frontend responding (HTTP 200)

[TEST] Backend API
✓ PASS - Backend API responding (HTTP 200)

... (more tests)

═══════════════════════════════════════════════════════════════════════════
DEPLOYMENT COMPLETE
✓ TEST VM DEPLOYMENT COMPLETE

Access Points:
  Frontend:     http://localhost:3000/
  Admin Panel:  http://localhost:8000/admin/
  API:          http://localhost:8000/api/
  Database:     localhost:13306
  
READY FOR TESTING!
```

---

## 📊 Script Architecture

```
SOURCE VM
├─ source-vm-prepare.sh
│  ├─ Check prerequisites
│  ├─ Create package directory
│  │  ├─ Copy docker/
│  │  ├─ Copy offline/
│  │  ├─ Copy backend/
│  │  ├─ Copy frontend/
│  │  ├─ Copy ansible/
│  │  ├─ Copy terraform/
│  │  ├─ Copy docker-compose.offline.yml
│  │  └─ Copy .env
│  ├─ Create tar.gz archive
│  ├─ Verify archive integrity
│  ├─ Transfer via SCP
│  └─ Generate checksums
│
│                          ↓ SCP Transfer (3-4 GB)
│
TEST VM (192.168.72.244)
└─ test-vm-deploy.sh
   ├─ Verify Docker
   ├─ Extract archive
   ├─ Verify offline resources
   ├─ Configure environment
   ├─ Build Docker images
   │  ├─ backend-offline
   │  ├─ conversion-worker-offline
   │  └─ frontend-offline
   ├─ Deploy services
   │  ├─ Backend API
   │  ├─ Frontend
   │  ├─ Celery Worker
   │  ├─ Celery Beat
   │  ├─ MariaDB
   │  └─ Redis
   ├─ Initialize database
   ├─ Run 10 tests
   └─ Generate report
```

---

## ⏱️ Timeline

| Step | Duration | Notes |
|------|----------|-------|
| **Source VM**: Prepare | 2-3 min | Package creation, archive |
| **Network**: Transfer | 5-10 min | Depends on network speed (3-4 GB) |
| **Test VM**: Extract | 30 sec | Decompress archive |
| **Test VM**: Docker setup | 1 min | Verify Docker |
| **Test VM**: Build images | 10-15 min | First-time build slower |
| **Test VM**: Deploy | 1-2 min | Start containers |
| **Test VM**: Initialize DB | 2-3 min | Run migrations |
| **Test VM**: Test suite | 2-3 min | Comprehensive validation |
| **Test VM**: Report | <1 min | Generate summary |
| **TOTAL** | ~35-45 min | One-time setup |

---

## 🔍 Monitoring Progress

### On Source VM
```bash
# Watch transfer in real-time
tail -f ~/vm-migrator-offline-*.log

# Check archive size
ls -lh ~/vm-migrator-offline-*.tar.gz
```

### On Test VM
```bash
# Watch deployment in real-time
tail -f ~/vm-migrator-test-*/deployment.log

# Check image building
docker images | grep vm-migrator

# Monitor running services
docker ps -a

# Watch service logs
docker-compose -f docker-compose.offline.yml logs -f
```

---

## 🆘 Troubleshooting

### Source VM Issues

**"Failed to create archive"**
- Check disk space: `df -h ~`
- Ensure write permissions: `touch ~/test-write` && `rm ~/test-write`

**"SCP transfer failed"**
- Verify SSH access: `ssh amin@192.168.72.244 echo OK`
- Check network: `ping 192.168.72.244`
- Verify target directory will be created

**"Low disk space warning"**
- Archive needs 5+ GB free space
- Clean up: `rm -rf ~/vm-migrator-offline-*.tar.gz` (old files)

### Test VM Issues

**"Docker not running"**
```bash
sudo systemctl start docker
sudo usermod -aG docker $USER
newgrp docker
```

**"Build script not executable"**
```bash
cd ~/vm-migrator-deploy/vm-migrator-offline-*
chmod +x docker/scripts/build-offline.sh
```

**"Out of disk space during build"**
```bash
# Check available space
df -h

# Need 50+ GB, make space if needed
docker system prune -a
```

**"Services won't start"**
```bash
# Check error logs
docker-compose -f docker-compose.offline.yml logs

# Check for port conflicts
lsof -i :8000
lsof -i :3000
```

---

## 📋 Success Criteria

### After Source VM Script
- ✅ Archive created (~3-4 GB)
- ✅ Checksum calculated
- ✅ Files transferred via SCP
- ✅ Transfer verified
- ✅ Deployment script transferred

### After Test VM Script
- ✅ Archive extracted
- ✅ 3 Docker images built
- ✅ 6 Services running
- ✅ Database initialized
- ✅ All 10 tests passing
- ✅ Frontend accessible at localhost:3000
- ✅ Admin panel accessible at localhost:8000/admin

---

## 📞 Next Steps After Testing

1. **Review Test Report**
   ```bash
   cat ~/vm-migrator-test-*/test-report.log
   ```

2. **Access the Application**
   - Frontend: http://localhost:3000
   - Admin: http://localhost:8000/admin
   - API: http://localhost:8000/api

3. **Monitor Logs**
   ```bash
   docker-compose -f docker-compose.offline.yml logs -f
   ```

4. **Run Additional Tests** (as needed)
   ```bash
   docker-compose -f docker-compose.offline.yml exec backend bash
   python manage.py test
   ```

5. **Document Results**
   - Save test reports
   - Note any configuration changes
   - Document performance metrics

---

**Version**: 1.0  
**Created**: May 11, 2026  
**Test VM**: Ubuntu 26, amin@192.168.72.244
