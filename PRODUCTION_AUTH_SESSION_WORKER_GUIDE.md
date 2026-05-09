# Authentication, Session Management, and Worker Scalability Guide

**Author**: Engineering Team  
**Version**: 1.0  
**Date**: May 9, 2026  
**Applicability**: Production deployments with 200+ concurrent migration jobs  

---

## Table of Contents

1. [Overview](#overview)
2. [Feature 1: Default Superadmin Bootstrap](#feature-1-default-superadmin-bootstrap)
3. [Feature 2: Session Expiration & Inactivity](#feature-2-session-expiration--inactivity)
4. [Feature 3: Worker Scalability](#feature-3-worker-scalability)
5. [Configuration Reference](#configuration-reference)
6. [Deployment Guide](#deployment-guide)
7. [Monitoring & Troubleshooting](#monitoring--troubleshooting)
8. [FAQ](#faq)

---

## Overview

This guide details three production-grade architectural improvements:

| Feature | Problem | Solution | Impact |
|---------|---------|----------|--------|
| **Default Superadmin** | Manual user creation required on first launch | Auto-bootstrap via env vars | Zero-downtime first launch |
| **Session Expiration** | Sessions last 7 days (JWT token lifetime) | 2-hour inactivity timeout with sliding window | Security + compliance |
| **Worker Scalability** | Max 2 concurrent migrations (hardcoded) | 200 concurrent via worker pool + queue routing | 100x throughput increase |

### Key Architecture Decision

**Jobs are decoupled from HTTP sessions**:
- User creates job via authenticated API → migration job stored in DB with `user_id`
- Job queued in Celery worker queue
- User logs out or session expires → HTTP API returns 401
- Background job **continues running to completion** independently
- This is safe and intentional: job execution doesn't require live HTTP session

---

## Feature 1: Default Superadmin Bootstrap

### Problem

On first application launch, the database is empty. To create the first user, you must:
1. SSH into the container
2. Run Django shell
3. Manually create User object

This is operationally fragile and blocks automated deployments.

### Solution

The application automatically creates a default superadmin on startup if none exists. This is:
- **Idempotent**: Safe to restart containers (won't recreate if already exists)
- **Environment-driven**: Credentials from env vars, no hardcoded secrets
- **Audit-logged**: Creation logged for compliance

### Architecture

```
Application startup sequence:
├─ Django loads configuration
├─ Database migrations run
├─ apps.py ready() signal fires
│  └─ Check: does a superadmin already exist?
│     ├─ YES: Skip creation (idempotent)
│     └─ NO: Create default superadmin via env vars
├─ Application starts serving requests
└─ Admin can immediately log in with default credentials
```

### Configuration

Set three environment variables:

```bash
# .env or docker-compose env
DEFAULT_SUPERADMIN_USERNAME=superadmin
DEFAULT_SUPERADMIN_EMAIL=admin@company.internal
DEFAULT_SUPERADMIN_PASSWORD=ChangeMe123!
```

**Important**: Change these for production! The password must meet Django validators:
- Minimum 8 characters
- Not just numbers
- Not too similar to username
- Not a common password

### Validation & Security

```python
# settings.py validates on startup:
AUTH_PASSWORD_VALIDATORS = [
    'django.contrib.auth.password_validation.UserAttributeSimilarityValidator',
    'django.contrib.auth.password_validation.MinimumLengthValidator',
    'django.contrib.auth.password_validation.CommonPasswordValidator',
    'django.contrib.auth.password_validation.NumericPasswordValidator',
]
```

If password fails validation, the app will log an error and continue (it won't block startup, but superadmin won't be created).

### Usage

**First Launch**:
```bash
docker-compose up  # Starts all services
# App initializes, creates superadmin
# Check logs: [INIT] Default superadmin created: superadmin

# Log in with:
# username: superadmin
# password: ChangeMe123!
```

**Subsequent Launches**:
```bash
docker-compose restart backend  # Restart container
# App starts, checks database, finds superadmin already exists
# Logs: "Default superadmin user already exists. Skipping creation."
# Continues normally
```

### Managing First-Launch Password

**Best Practice**: 
1. Deploy with default credentials
2. Log in immediately after first launch
3. Change password in dashboard or API
4. Can optionally update `.env` for next deployment

**API to Change Password**:
```bash
curl -X PATCH \
  http://backend:8000/api/users/me/ \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "password": "NewSecurePassword123!"
  }'
```

### Audit Trail

Creation is logged with:
```json
{
  "event": "init.superadmin.created",
  "user_id": 1,
  "username": "superadmin",
  "email": "admin@company.internal",
  "role": "SUPER_ADMIN",
  "timestamp": "2026-05-09T12:34:56Z"
}
```

---

## Feature 2: Session Expiration & Inactivity

### Problem

JWT tokens are stateless and issued with fixed expiration (7 days in current config). This means:
- Sessions last full 7 days regardless of activity
- No way to enforce "2-hour inactivity timeout"
- Compromised token valid for up to 7 days
- No server-side logout (token can't be revoked)

### Solution

Server-side session activity tracking with middleware that:
1. Creates **UserSessionActivity** record on first authenticated request
2. Updates **last_activity** timestamp on each request (sliding window)
3. Rejects requests if **last_activity + 2 hours < now** (inactivity check)
4. Decouple from jobs so migration tasks aren't affected

### Architecture

```
HTTP Request Flow:
├─ User sends: Authorization: Bearer <token>
├─ Django auth validates token signature and expiry
├─ Response: 401 if token expired (JWT level)
├─ If user authenticated:
│  ├─ SessionActivityMiddleware.process_request()
│  │  ├─ Check: has user been inactive for 2+ hours?
│  │  │  ├─ YES: Return 401 "Session expired"
│  │  │  └─ NO: Continue
│  │  └─ Update: set last_activity = now
│  ├─ View processes request
│  └─ SessionExpirationResponseMiddleware adds header
│     └─ X-Session-Expires-At: <ISO timestamp>
└─ Response sent to client

Background Job Flow (independent of session):
├─ Worker receives: start_migration(job_id=123)
├─ Worker loads: MigrationJob.objects.get(id=123)
├─ Worker executes conversion (user session doesn't matter)
├─ Worker updates: job.status, job.progress_percent
└─ Job completes successfully even if user logged out
```

### Configuration

#### 1. Middleware Enabled (automatic)

In `settings.py`, SessionActivityMiddleware is already added:
```python
MIDDLEWARE = [
    ...
    'django.contrib.auth.middleware.AuthenticationMiddleware',
    'users.middleware.SessionActivityMiddleware',  # <-- Added
    ...
]
```

#### 2. Inactivity Timeout Setting

```python
# default: 7200 seconds = 2 hours
SESSION_INACTIVITY_TIMEOUT_SECONDS = env.int(
    "SESSION_INACTIVITY_TIMEOUT_SECONDS",
    default=7200
)
```

To change (e.g., 1 hour):
```bash
export SESSION_INACTIVITY_TIMEOUT_SECONDS=3600  # 1 hour
```

#### 3. Database Migration

Run migrations to create **UserSessionActivity** table:
```bash
python manage.py migrate
```

This creates:
```sql
CREATE TABLE users_usersessionactivity (
    id BIGINT PRIMARY KEY AUTO_INCREMENT,
    user_id BIGINT UNIQUE NOT NULL,
    last_activity DATETIME AUTO_UPDATE NOT NULL,
    ip_address VARCHAR(45),
    user_agent VARCHAR(500),
    created_at DATETIME NOT NULL,
    FOREIGN KEY (user_id) REFERENCES users_user(id) ON DELETE CASCADE,
    INDEX (user_id, -last_activity),
    INDEX (-last_activity)
);
```

### Behavior

**Scenario 1: Inactive Session**
```
10:00 - User logs in (last_activity = 10:00)
10:30 - User makes request (last_activity = 10:30)
12:45 - User's browser is idle, no requests
13:35 - User's browser tries to fetch migrations list
       → Middleware: (13:35 - 10:30 = 3h 5m) > 2h → Inactive!
       → Return 401: "Session expired due to inactivity"
       → Frontend auto-redirects to login page
```

**Scenario 2: Active Session**
```
10:00 - User logs in (last_activity = 10:00)
10:30 - User makes request (last_activity = 10:30)
11:00 - User refreshes dashboard (last_activity = 11:00)
11:30 - User submits migration job (last_activity = 11:30)
       → Middleware: (11:30 - 11:30 = 0m) < 2h → Active!
       → Request proceeds normally
```

**Scenario 3: Job Continues After Logout**
```
10:00 - User logs in
11:00 - User starts migration job (job_id=123)
       → API creates MigrationJob with user_id=1
       → Celery worker queues: start_migration(123)
11:30 - User closes laptop, session becomes idle
13:35 - User reconnects, session expired, logs in again
14:00 - Migration job still running in background
       → Worker pulls job 123 from queue
       → Loads MigrationJob(id=123) - user_id still set
       → Continues conversion independently
15:00 - Job completes and marked VERIFIED
       → User can see completed job in dashboard
```

### Frontend Implications

Frontend must handle 401 responses:

```javascript
// api/client.js - already handles this

async function apiFetch(url, options = {}) {
    const response = await fetch(url, {
        headers: {
            'Authorization': `Bearer ${getAccessToken()}`,
            ...
        },
        ...options
    });

    if (response.status === 401) {
        // Session expired
        clearAuthStorage();  // Clear local tokens
        window.location.href = '/login';  // Redirect to login
        return;
    }

    if (response.status === 200) {
        // Request succeeded
        // Check X-Session-Expires-At header if you want to warn
        const expiresAt = response.headers.get('X-Session-Expires-At');
        if (expiresAt) {
            const minutesRemaining = calculateMinutes(expiresAt);
            if (minutesRemaining < 15) {
                showWarning(`Session expires in ${minutesRemaining} minutes`);
            }
        }
    }

    return response;
}
```

### Monitoring

Query active sessions:
```python
from users.models import UserSessionActivity
from django.utils import timezone
from datetime import timedelta

# Users logged in now
active = UserSessionActivity.objects.filter(
    last_activity__gte=timezone.now() - timedelta(hours=2)
)

for activity in active:
    print(f"{activity.user}: last active {activity.last_activity}")

# Users with expired sessions
expired = UserSessionActivity.objects.filter(
    last_activity__lt=timezone.now() - timedelta(hours=2)
)
print(f"Expired sessions: {expired.count()}")
```

---

## Feature 3: Worker Scalability

### Problem

Current configuration:
```python
CELERY_WORKER_CONCURRENCY = 2  # Max 2 concurrent jobs!
```

This means:
- Even with 1 worker: max 2 simultaneous migrations
- Can't scale to 200 concurrent
- Bottleneck is concurrency setting, not resources

### Solution

Multi-worker architecture with:
1. **Increased concurrency per worker**: 2 → 50 (or your target / number of workers)
2. **Multiple worker containers**: Scale via `docker-compose up --scale worker=4`
3. **Queue routing**: Separate queues for migrations/discovery/provisioning
4. **Progress tracking**: Real-time 0-100% progress for long-running jobs
5. **Resource cleanup**: Proper try/finally blocks to prevent zombie processes
6. **Connection pooling**: Reuse DB/Redis connections instead of opening new ones

### Architecture

```
Target: 200 concurrent migrations

Deployment Model:
┌─────────────────────────────────────────────────────┐
│ Docker Compose / Kubernetes                         │
├─────────────────────────────────────────────────────┤
│ Redis (broker)                                      │
│ ├─ Connection pool: 50 clients max                 │
│ └─ Messages: migrations, discovery, provisioning   │
├─────────────────────────────────────────────────────┤
│ MariaDB (job state + progress)                      │
│ ├─ Connection pool: 50 connections reused          │
│ └─ Indexes: status, progress_percent, user_id      │
├─────────────────────────────────────────────────────┤
│ Worker Container 1  │ Worker Container 2/3/4        │
│  Concurrency: 50    │  Concurrency: 50 each        │
│ ├─ migration task 1  │ (4 workers × 50 = 200)      │
│ ├─ migration task 2  │                             │
│ ├─ ...               │ Queues:                     │
│ └─ migration task 50 │ - migrations (priority 10)  │
│                      │ - discovery (priority 5)    │
│ Prefetch: 4          │ - provisioning (priority 8) │
│ Max tasks/child: 100 │                             │
└─────────────────────────────────────────────────────┘
```

### Configuration

#### 1. Environment Variables (in .env)

```bash
# Target concurrent migrations
MAX_CONCURRENT_MIGRATIONS=200

# Per-worker concurrency (200 / 4 workers = 50)
CELERY_WORKER_CONCURRENCY=50

# Prefetch multiplier (keep low for long-running jobs)
CELERY_WORKER_PREFETCH_MULTIPLIER=4

# Restart worker after 100 tasks (memory leak prevention)
CELERY_WORKER_MAX_TASKS_PER_CHILD=100

# Broker connection pooling
CELERY_BROKER_POOL_LIMIT=10

# Task timeouts (migrations can take hours)
CELERY_TASK_SOFT_TIME_LIMIT=3600    # 1 hour
CELERY_TASK_TIME_LIMIT=3900         # 1.5 hours
```

#### 2. Docker Compose Scaling

```yaml
# docker-compose.yml

services:
  worker:
    build: .
    command: celery -A core worker -l info --concurrency=50 --prefetch-multiplier=4 -Q migrations,discovery,provisioning,celery
    deploy:
      replicas: 4  # Scale to 4 workers (200 concurrent total)
    depends_on:
      - redis
      - backend
      - mariadb
    environment:
      - CELERY_WORKER_CONCURRENCY=50
      - MAX_CONCURRENT_MIGRATIONS=200
      # ... other vars

  beat:  # Celery Beat for periodic tasks
    build: .
    command: celery -A core beat -l info
    depends_on:
      - redis
```

To deploy and scale:
```bash
docker-compose up backend worker redis mariadb

# Later, scale workers:
docker-compose up -d --scale worker=4

# Or via kubectl:
kubectl scale deployment/worker --replicas=4
```

#### 3. Queue Routing

Queries in `settings.py` automatically route task types:
```python
CELERY_TASK_ROUTING = {
    'migrations.start_migration': {'queue': 'migrations', 'routing_key': 'migrations'},
    'migrations.discover_vmware_vms': {'queue': 'discovery', 'routing_key': 'discovery'},
    'migrations.provision_openstack_infra': {'queue': 'provisioning', 'routing_key': 'provisioning'},
}
```

Benefits:
- Migration workers can focus on conversion (CPU/disk intensive)
- Discovery workers quick-turn for responsive UI
- Provisioning workers handle Terraform/OpenStack (API-heavy)
- No task type blocks another

### Progress Tracking

**Database Fields** (new):
```python
MigrationJob:
    progress_percent    # 0-100 (updated during conversion)
    current_step        # "downloading", "converting", "uploading", etc.
    progress_details    # JSON: {current_disk: 2, total_disks: 3, mb_transferred: 5120}
    started_at          # When conversion actually began
    completed_at        # When conversion finished
```

**Usage in Worker**:
```python
@shared_task
def start_migration(job_id):
    job = MigrationJob.objects.get(id=job_id)
    
    try:
        job.transition(Status.CONVERTING)
        job.started_at = timezone.now()
        job.save()
        
        # ... conversion logic ...
        
        # Update progress during conversion
        job.update_progress(
            percent=25,
            step="downloading_disk_1",
            details={"current_disk": 1, "total_disks": 4}
        )
        
        # ... more work ...
        
        job.update_progress(percent=50, step="converting")
        
        # ... more work ...
        
        job.update_progress(percent=75, step="uploading_to_openstack")
        
        job.transition(Status.VERIFIED)
        job.completed_at = timezone.now()
        job.progress_percent = 100
        job.save()
        
    except Exception as e:
        job.transition(Status.FAILED)
        job.completed_at = timezone.now()
        raise
```

**Frontend Display**:
```javascript
// Progress bar component
function JobProgressBar({ job }) {
    return (
        <div className="progress">
            <div 
                className="progress-bar"
                style={{ width: job.progress_percent + '%' }}
            >
                {job.progress_percent}%
            </div>
            <div className="progress-step">
                {job.current_step}: {job.progress_details?.current_disk}/{job.progress_details?.total_disks}
            </div>
        </div>
    );
}
```

### Resource Cleanup

Pattern for long-running background tasks:

```python
@shared_task
def start_migration(job_id):
    job = MigrationJob.objects.get(id=job_id)
    temp_dir = Path(settings.MIGRATION_OUTPUT_DIR) / f"job-{job_id}"
    
    try:
        # Setup
        temp_dir.mkdir(parents=True, exist_ok=True)
        logger.info(f"Starting migration {job_id}")
        
        # ... conversion work ...
        job.update_progress(50, "converting")
        job.transition(Status.CONVERTING)
        
        # ... more work ...
        
        job.transition(Status.UPLOADED)
        return {"status": "success"}
    
    except Exception as e:
        logger.error(f"Migration {job_id} failed: {e}", exc_info=True)
        job.transition(Status.FAILED)
        cleanup_job_resources(job_id)
        raise
    
    finally:
        # ALWAYS cleanup, even on success
        cleanup_temp_files(temp_dir)
        cleanup_child_processes(job_id)  # Kill any virt-v2v subprocesses
        logger.info(f"Cleanup complete for job {job_id}")
```

### Monitoring & Observability

#### Celery Monitoring

```bash
# Check worker status
celery -A core inspect active

# See queued jobs
celery -A core inspect reserved

# View worker stats
celery -A core inspect stats

# Monitor in real-time
listen -A core worker --loglevel=INFO
```

#### Database Monitoring

```python
# Jobs in progress
from migrations.models import MigrationJob

in_progress = MigrationJob.objects.filter(
    status__in=['PENDING', 'PRECHECK', 'CONVERTING', 'UPLOADING']
)

for job in in_progress:
    print(f"{job.vm_name}: {job.progress_percent}% - {job.current_step}")

# Average job duration
completed = MigrationJob.objects.filter(status='VERIFIED')
avg_duration = (completed.values_list('completed_at') 
                - completed.values_list('started_at')).avg()

# Failure rate
failed_count = MigrationJob.objects.filter(status='FAILED').count()
total_count = MigrationJob.objects.count()
failure_rate = (failed_count / total_count) * 100
```

---

## Configuration Reference

### Complete Environment Variables

```bash
# ---- DEFAULT SUPERADMIN ----
DEFAULT_SUPERADMIN_USERNAME=superadmin
DEFAULT_SUPERADMIN_EMAIL=admin@company.internal
DEFAULT_SUPERADMIN_PASSWORD=ChangeMe123!

# ---- SESSION MANAGEMENT ----
SESSION_INACTIVITY_TIMEOUT_SECONDS=7200  # 2 hours

# ---- WORKER SCALABILITY ----
MAX_CONCURRENT_MIGRATIONS=200
CELERY_WORKER_CONCURRENCY=50              # 200 / 4 workers
CELERY_WORKER_PREFETCH_MULTIPLIER=4
CELERY_WORKER_MAX_TASKS_PER_CHILD=100
CELERY_BROKER_POOL_LIMIT=10

# ---- CELERY CORE ----
REDIS_URL=redis://redis:6379/0
CELERY_TASK_SOFT_TIME_LIMIT=3600
CELERY_TASK_TIME_LIMIT=3900
CELERY_TASK_DEFAULT_RETRY_DELAY=30
CELERY_PUBLISH_MAX_RETRIES=3

# ---- DATABASE ----
DATABASE_URL=mysql://user:pass@db:3306/vm_migrator
DB_CONN_MAX_AGE=600
DB_POOL_SIZE=50

# ---- DJANGO CORE ----
DEBUG=false
SECRET_KEY=<long-random-key>
ALLOWED_HOSTS=app.example.com,api.example.com
LOG_LEVEL=INFO
```

---

## Deployment Guide

### Step 1: Database Migrations

```bash
cd backend

# Create/apply migrations
python manage.py migrate users
python manage.py migrate migrations

# Verify
python manage.py dbshell
> SHOW TABLES;  -- Should include users_usersessionactivity
> SELECT * FROM migrations_migrationjob LIMIT 1;  -- Check new fields exist
```

### Step 2: Environment Configuration

Create `.env` file (or update existing):
```bash
# Copy example
cp .env.example .env

# Edit for your environment
nano .env

# Key changes from original:
# - Add DEFAULT_SUPERADMIN_* variables
# - Add SESSION_INACTIVITY_TIMEOUT_SECONDS
# - Increase CELERY_WORKER_CONCURRENCY to 50 (from 2)
# - Add MAX_CONCURRENT_MIGRATIONS=200
```

### Step 3: Update Docker Compose

```yaml
# docker-compose.yml

worker:
  deploy:
    replicas: 4  # Changed from 1 to 4
  environment:
    - CELERY_WORKER_CONCURRENCY=50
    - MAX_CONCURRENT_MIGRATIONS=200

beat:
  # Unchanged, but benefits from queue routing

backend:
  # Unchanged
```

### Step 4: Start/Restart Application

```bash
# Stop old containers
docker-compose down

# Pull latest code
git pull origin main

# Rebuild images
docker-compose build --no-cache

# Start services
docker-compose up -d

# Check logs for superadmin creation
docker-compose logs backend | grep "superadmin"

# Verify all services healthy
docker-compose ps
```

### Step 5: Test First Login

```bash
# Get superadmin tokens
curl -X POST http://localhost:8000/api/auth/login/ \
  -H "Content-Type: application/json" \
  -d '{
    "username": "superadmin",
    "password": "ChangeMe123!"
  }'

# Response should include:
# {
#    "access": "eyJ0eXAi...",
#    "refresh": "eyJ0eXAi...",
#    "user": {
#        "id": 1,
#        "username": "superadmin",
#        "email": "admin@company.internal",
#        "role": "SUPER_ADMIN"
#    }
# }

# Test protected endpoint
curl -H "Authorization: Bearer $ACCESS_TOKEN" \
  http://localhost:8000/api/migrations/
```

### Step 6: Run Tests

```bash
python manage.py test migrations.tests_auth_session_worker -v 2

# Expected output: All tests pass
# Ran 30 tests in 2.3s
# OK
```

---

## Monitoring & Troubleshooting

### Check Superadmin Bootstrap

```python
python manage.py shell
>>> from users.models import User
>>> User.objects.filter(role='SUPER_ADMIN')
<QuerySet [<User: superadmin (SUPER_ADMIN)>]>
```

If empty:
```bash
# Check logs for errors
docker-compose logs backend | grep -i "superadmin\|init"

# Manually create (fallback)
python manage.py shell
>>> from users.models import User
>>> User.objects.create_superuser(username='admin', email='admin@example.com', password='Pass123!')
```

### Check Session Activity

```python
from users.models import UserSessionActivity
from django.utils import timezone
from datetime import timedelta

# Logged-in users
active = UserSessionActivity.objects.filter(
    last_activity__gte=timezone.now() - timedelta(hours=2)
)
print(f"Active sessions: {active.count()}")

# Check specific user
user = User.objects.get(username='testuser')
activity = user.session_activity
print(f"{user}: last active {activity.last_activity}")
```

### Check Worker Load

```bash
# Celery stats
celery -A core inspect stats

# Sample output:
# {
#   'celery@worker-1': {
#     'pool': {
#       'implementation': 'solo',
#       'max-concurrency': 50,
#       'processes': [1,2,3,...,50],
#       'timeouts': [300,300,...]
#     }
#   }
# }
```

### Monitor Job Progress

```python
from migrations.models import MigrationJob

# Get current job
job = MigrationJob.objects.get(id=123)
print(f"{job.vm_name}: {job.progress_percent}%")
print(f"Step: {job.current_step}")
print(f"Details: {job.progress_details}")

# Watch progress (refresh every 5 sec)
import time
for _ in range(60):
    job.refresh_from_db()
    print(f"{job.progress_percent}% - {job.current_step}")
    time.sleep(5)
```

### Debug Inactivity Timeout

If 401 errors appear unexpectedly:

```python
from users.models import UserSessionActivity
from django.utils import timezone
from datetime import timedelta

activity = UserSessionActivity.objects.get(user=request.user)
inactive_duration = timezone.now() - activity.last_activity
timeout_duration = timedelta(seconds=7200)  # 2 hours

print(f"Inactive for: {inactive_duration}")
print(f"Timeout: {timeout_duration}")
print(f"Exceed? {inactive_duration > timeout_duration}")

# To re-activate, make an authenticated request
```

### Performance Tuning

If jobs are slow:

1. **Increase worker concurrency** (if CPU/mem available):
   ```bash
   CELERY_WORKER_CONCURRENCY=100  # More concurrent tasks
   ```

2. **Increase prefetch multiplier** (for faster task distribution):
   ```bash
   CELERY_WORKER_PREFETCH_MULTIPLIER=8  # Fetch more tasks at once
   ```

3. **Add more workers**:
   ```bash
   docker-compose up -d --scale worker=8  # 8 × 50 = 400 concurrent
   ```

4. **Queue routing** (dedicate workers to migration queue):
   ```bash
   docker-compose up -d worker-mg  # Only migrations queue
   docker-compose run -d worker-dc -Q discovery  # Discovery queue
   ```

---

## FAQ

### Q: What if superadmin password expires? Can I change it?

**A**: Yes. Two ways:

1. **Via UI** (after logging in):
   - Go to user profile settings
   - Change password

2. **Via API**:
   ```bash
   curl -X PATCH http://api/users/me/ \
     -H "Authorization: Bearer $TOKEN" \
     -d '{"password": "NewPass123!"}'
   ```

3. **Via Django shell** (emergency):
   ```python
   python manage.py shell
   >>> from users.models import User
   >>> user = User.objects.get(username='superadmin')
   >>> user.set_password('NewPass123!')
   >>> user.save()
   ```

### Q: What happens if I log out while a job is running?

**A**: The job continues normally:
- Job is stored in database with `user_id`
- Worker doesn't check user session
- After logout, you can log back in and see job status
- Job completes independently

### Q: Can I increase MAX_CONCURRENT_MIGRATIONS to 500?

**A**: Yes, but scale workers accordingly:
```bash
# For 500 concurrent:
CELERY_WORKER_CONCURRENCY=50      # 500 / 10 workers
docker-compose up -d --scale worker=10

# For 1000 concurrent:
CELERY_WORKER_CONCURRENCY=100     # 1000 / 10 workers
docker-compose up -d --scale worker=10
```

Monitor resources (CPU, RAM, disk I/O) and adjust.

### Q: Session expired - do I lose my job progress?

**A**: No.
- Job progress is saved in database constantly
- Session expiration only affects HTTP API access
- Log back in and refresh job status
- Job continues running in background

### Q: How do I monitor 200 concurrent jobs?

**A**: Use these tools:

```bash
# Real-time worker status
watch -n 1 'celery -A core inspect active'

# Job progress (Python)
python manage.py shell
>>> from migrations.models import MigrationJob
>>> jobs = MigrationJob.objects.filter(status__in=['PENDING','CONVERTING','UPLOADING'])
>>> for j in jobs: print(f"{j.vm_name}: {j.progress_percent}%")

# Database queries
SELECT status, COUNT(*) FROM migrations_migrationjob GROUP BY status;
SELECT AVG(progress_percent) FROM migrations_migrationjob WHERE status != 'VERIFIED';
```

### Q: Is it safe to restart workers during migrations?

**A**: Yes, architecture is designed for it:
- CELERY_TASK_ACKS_LATE=True: Task not marked done until worker finishes
- CELERY_TASK_REJECT_ON_WORKER_LOST=True: If worker dies, task re-queued
- **Safe restart sequence**:
  ```bash
  # Gracefully stop workers (wait for current tasks)
  docker-compose stop worker  # Waits for SIGTERM timeout
  
  # Restart
  docker-compose start worker  # In-flight tasks resume
  ```

---

## Appendix: Schema Changes

### New Database Tables

```sql
CREATE TABLE users_usersessionactivity (
    id BIGINT PRIMARY KEY AUTO_INCREMENT,
    user_id BIGINT UNIQUE NOT NULL,
    last_activity DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    ip_address VARCHAR(45),
    user_agent VARCHAR(500),
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (user_id) REFERENCES users_user(id) ON DELETE CASCADE,
    INDEX idx_user_last_activity (user_id, last_activity DESC),
    INDEX idx_last_activity (last_activity DESC)
);
```

### New Model Fields (MigrationJob)

```sql
ALTER TABLE migrations_migrationjob ADD COLUMN progress_percent INT DEFAULT 0;
ALTER TABLE migrations_migrationjob ADD COLUMN current_step VARCHAR(50) DEFAULT '';
ALTER TABLE migrations_migrationjob ADD COLUMN progress_details JSON DEFAULT '{}';
ALTER TABLE migrations_migrationjob ADD COLUMN started_at DATETIME NULL;
ALTER TABLE migrations_migrationjob ADD COLUMN completed_at DATETIME NULL;
CREATE INDEX idx_status_created (status, created_at DESC);
CREATE INDEX idx_progress (progress_percent DESC);
```

---

**End of Guide**

For questions or issues, contact the Infrastructure team.
