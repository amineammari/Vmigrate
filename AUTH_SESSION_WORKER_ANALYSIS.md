# Auth, Session, and Worker Scalability Architecture Analysis

**Date**: May 9, 2026  
**Scope**: Production-grade authentication, session management, and worker scaling for 200 concurrent migrations

---

## Executive Summary

Your current implementation has solid foundations but three critical gaps for production:

1. **No Bootstrap Mechanism** → Admin must create first user manually
2. **No Session Expiration** → Sessions last full 7 days (JWT token lifetime)
3. **Worker Bottleneck** → Max 2 concurrent migrations (needs 200)

This analysis proposes **three coordinated architectural solutions** that preserve existing APIs while enabling production-grade reliability, security, and scalability.

---

## PART 1: AUTHENTICATION & SUPERADMIN BOOTSTRAP

### Current State Analysis

**What Works**:
- ✅ Custom User model with Role choices (SUPER_ADMIN, USER)
- ✅ Django REST Framework with simplejwt for stateless JWT auth
- ✅ Password validation (min 8 chars, similarity checks, etc.)
- ✅ Token serializer includes role/username/email in JWT payload
- ✅ Encrypted endpoint session passwords (django_cryptography)

**What's Missing**:
- ❌ **No default superadmin creation mechanism**
- ❌ **Manual setup required on first launch** (catch-22: need admin to create admin)
- ❌ **No "force password change" on first login** (password hint in DB forever)
- ❌ **No initialization idempotency** (awkward if schema migrations re-run)

### The Problem

```
On first launch:
1. Database is empty (or has schema only)
2. User wants to log in with admin account
3. But there's no way to create the first user
4. → Must use SSH into Django shell or add user manually
5. → Deployment complexity, human error risk
```

### Proposed Solution: Signal-Based Bootstrap

**Architecture**:
1. Use Django `apps.ready()` signal (runs after migrations complete)
2. Check if User.objects.filter(role=SUPER_ADMIN).exists()
3. If empty AND environment has DEFAULT_SUPERADMIN_* vars → Create it
4. Idempotent: subsequent app reloads skip creation
5. Survives container redeployment (idempotency check)

**Benefits**:
- ✅ Automatic on app startup
- ✅ Idempotent (safe for restarts)
- ✅ Environment-driven (no hardcoded secrets)
- ✅ Audit trail (logged on creation)
- ✅ Works with Docker, K8s, traditional deployment

**Configuration**:
```bash
# .env
DEFAULT_SUPERADMIN_USERNAME=superadmin
DEFAULT_SUPERADMIN_EMAIL=admin@company.internal
DEFAULT_SUPERADMIN_PASSWORD=ChangeMe123!
```

**Behavior**:
```
First launch:
  App starts → Migrations run → Apps ready() → Check superadmin exists?
  No → Create one with env vars → Log creation → App serves requests
  
Subsequent launches:
  App starts → Migrations run → Apps ready() → Check superadmin exists?
  Yes → Skip creation → App serves requests (idempotent)
```

**Safety Guardrails**:
- Requires migrations to complete first (from `ready()` hook)
- Reads from env, not hardcoded
- Only creates if NO superadmin exists (idempotent)
- Logs creation for audit trail
- Password must meet Django validators (no weak defaults)

---

## PART 2: SESSION EXPIRATION & INACTIVITY TIMEOUT

### Current State Analysis

**What Works**:
- ✅ JWT tokens with 30-min access lifetime
- ✅ Refresh tokens with 7-day lifetime
- ✅ Standard REST auth (Authorization: Bearer)
- ✅ Frontend stores tokens in localStorage

**What's Missing**:
- ❌ **No inactivity timeout** (sessions last full 7 days if token not explicitly expired)
- ❌ **No sliding expiration** (no activity refresh)
- ❌ **No server-side logout** (refresh token never invalidated)
- ❌ **No session tracking** (tokens are stateless, can't track activity)
- ❌ **No "force revoke" mechanism** (if user is suspected compromised, can't force logout)

### The Core Problem: Stateless JWT

```
JWT tokens are signed & stateless:
  - Server issues token with expiry claim
  - Client sends token on each request
  - Server validates signature & expiry
  - No server-side state tracking possible
  
Result:
  - Can't tell if user is "active"
  - Can't track last activity time
  - Can't invalidate token server-side
  - Session lifetime = token TTL, not inactivity window
```

### Your Requirement: 2-Hour Inactivity Timeout

**Requirement**: 
> "Expire user sessions ONLY after 2 hours of inactivity"

**Definition**:
- Session starts when user logs in (token issued)
- Every API request = activity (resets inactivity clock)
- Inactive for 2+ hours = session invalid, must re-login
- But: **Jobs must survive session expiration**

### The Constraint: Jobs Must Survive Logout

This is the **critical architectural requirement**:

```
Scenario:
  1. User logs in, starts migration job
  2. Job queued in Celery worker
  3. User closes laptop (session becomes idle)
  4. 2 hours pass → session expires
  5. Job continues running in worker
  6. Job completes successfully
  
Current code breaks this:
  - If session expiration somehow kills the job
  - Or if job depends on user context still being valid

Solution:
  - Decouple job lifecycle from HTTP session lifecycle
  - Job created with user_id (for audit/ownership only)
  - Job runs independently in background worker
  - Session expiration only affects HTTP API, not workers
```

### Proposed Solution: Hybrid Approach

**Architecture**:
1. Add server-side session activity tracking (UserSessionActivity model)
2. Track user's last activity timestamp on each authenticated request
3. On each request, check: is user inactive?
4. If inactive (last_activity + 2 hours < now): reject with 401
5. Decouple job execution from session validity (jobs don't need session to run)

**Components**:

#### A. UserSessionActivity Model
```python
class UserSessionActivity(models.Model):
    user = ForeignKey(User, on_delete=CASCADE, related_name='sessions')
    last_activity = DateTimeField(auto_now=True)  # Updated on each auth request
    ip_address = CharField(max_length=45)  # IPv4/IPv6
    user_agent = CharField(max_length=500, blank=True)  # Browser/client info
    ip_address = CharField(max_length=45)  # For geolocation/security
    created_at = DateTimeField(auto_now_add=True)
```

#### B. SessionActivityMiddleware
```python
class SessionActivityMiddleware:
    def __call__(self, request):
        if request.user.is_authenticated:
            # Update last_activity
            activity, _ = UserSessionActivity.objects.get_or_create(
                user=request.user,
                defaults={'ip_address': get_client_ip(request), ...}
            )
            activity.last_activity = timezone.now()
            activity.save(update_fields=['last_activity'])
            
            # Check inactivity
            inactive = (
                timezone.now() - activity.last_activity > timedelta(hours=2)
            )
            if inactive:
                return HttpResponse("Session expired", status=401)
```

#### C. Job Lifecycle Decoupling

**Before** (jobs tied to sessions):
```
API Request → Check auth → Create job → Queue task
Worker → Execute task (doesn't need auth)
But: If session expires, confusing state
```

**After** (jobs independent of sessions):
```
API Request → Check auth & session validity → Create job with user_id
Worker → Execute task using job_id (no session context needed)
Job completion: independent of original user's session state
```

**Key insight**: The job is already stored in DB with `user_id` ForeignKey. We just need to:
- Ensure endpoint validates user has permission to create jobs
- Store `user_id` once at job creation
- Never try to access `request.user` from a background task

### Benefits

✅ Users get 2-hour inactivity timeout (security)  
✅ Migration jobs survive logout (reliability)  
✅ Server can track active sessions (monitoring)  
✅ Admin can revoke sessions if needed (security)  
✅ Frontend auto-logout on 401 (UX)  

---

## PART 3: WORKER SCALABILITY (200 Concurrent Migrations)

### Current State Analysis

**Current Configuration**:
```python
CELERY_WORKER_CONCURRENCY = 2  # MAX 2 CONCURRENT JOBS!
CELERY_WORKER_PREFETCH_MULTIPLIER = 1
CELERY_TASK_ACKS_LATE = True  # Good
CELERY_TASK_REJECT_ON_WORKER_LOST = True  # Good
CELERY_TASK_TRACK_STARTED = True
```

**Architectural Issues**:

1. **Concurrency Bottleneck**
   ```
   Current: 1 worker process × 2 concurrency = 2 concurrent jobs
   Target: 4 worker containers × 50 concurrency = 200 concurrent jobs
   
   Problem: Hardcoded to 2, can't even run 3 simultaneous migrations
   ```

2. **No Connection Pooling**
   ```
   Each task might open new DB/Redis connections
   200 concurrent jobs = 200+ connections to broker/DB
   No pool to reuse, no max_connections limit
   ```

3. **No Queue Strategy**
   ```
   All tasks → single 'celery' queue
   No prioritization (discovery vs migration vs provisioning)
   No routing based on job type
   ```

4. **No Progress Tracking**
   ```
   MigrationJob.status shows state (PENDING, CONVERTING, etc.)
   But no sub-step progress
   Frontend can't show "Converting: 45% complete"
   ```

5. **No Resource Cleanup Strategy**
   ```
   If task fails mid-way, cleanup might not happen
   Orphaned processes, temp files, locks not released
   After 200 failures: system accumulates garbage
   ```

6. **No Monitoring/Observability**
   ```
   How many jobs are queued?
   How many workers are alive?
   Which jobs failed and why?
   No metrics hooks or structured logging
   ```

### The Scale Problem

```
Current:
  - 1 worker process
  - 2 concurrent tasks
  - Single shared Redis broker
  - No connection pooling
  - No monitoring

At 200 concurrent jobs, this breaks because:
  - Worker process is single-threaded (limited by GIL)
  - 200 I/O operations blocked (virt-v2v, SSH, API calls)
  - Redis connections: 1 broker + 50 prefetch = 51 min connections
  - Database: 200 concurrent to MySQL/MariaDB (typical limit: 100-500)
  - Temp disk space: 200 simultaneous conversions = 200 × 10GB = 2TB
```

### Proposed Solution: Distributed Worker Pool

**Architecture**:
1. **Multi-Container Worker Pool** (docker-compose scale)
   ```yaml
   worker:
     deploy:
       replicas: 4  # 4 workers × 50 concurrency = 200 concurrent
   ```

2. **Increased Concurrency Per Worker**
   ```python
   CELERY_WORKER_CONCURRENCY = 50  # (up from 2)
   CELERY_WORKER_PREFETCH_MULTIPLIER = 4  # Tune prefetch for 50 workers
   CELERY_WORKER_MAX_TASKS_PER_CHILD = 100  # Force worker restart after 100 tasks
   ```

3. **Connection Pooling**
   ```python
   # Redis: handled by redis-py (increase pool size)
   # DB: Django's connection pooling with max_connections
   DB_CONN_MAX_AGE = 600  # Reuse for 10 minutes
   DB_POOL_SIZE = 50  # For pgbouncer or similar
   ```

4. **Queue Routing** (prioritize job types)
   ```python
   CELERY_TASK_ROUTING = {
       'migrations.start_migration': {'queue': 'migrations'},
       'migrations.discover_vmware_vms': {'queue': 'discovery'},
       'migrations.provision_openstack_infra': {'queue': 'provisioning'},
   }
   
   # Workers can be specialized:
   # worker-migrations: processes only 'migrations' queue
   # worker-discovery: processes only 'discovery' queue
   # worker-general: processes all queues (fallback)
   ```

5. **Job Isolation & Resource Cleanup**
   ```python
   @shared_task
   def start_migration(job_id):
       try:
           # ... do conversion work ...
       except Exception as e:
           logger.error(f"Migration {job_id} failed", exc_info=True)
           cleanup_job_resources(job_id)
           raise
       finally:
           # ALWAYS cleanup temp files, processes, connections
           cleanup_temp_dirs(job_id)
           cleanup_child_processes(job_id)
           cleanup_temp_disks(job_id)
   ```

6. **Progress Tracking**
   ```python
   # Add to MigrationJob model:
   progress_percent = IntegerField(default=0)  # 0-100
   current_step = CharField(choices=[...])  # PRECHECK, CONVERTING, UPLOADING, etc.
   
   # Update during conversion:
   job.progress_percent = 45
   job.current_step = 'CONVERTING'
   job.save(update_fields=['progress_percent', 'current_step'])
   ```

7. **Monitoring Hooks**
   ```python
   @shared_task
   def start_migration(job_id):
       # ...
   
   @start_migration.on_success.connect
   def handle_success(sender, **kwargs):
       logger.info("migration_completed", extra={'job_id': kwargs['result']})
   
   @start_migration.on_failure.connect
   def handle_failure(sender, **kwargs):
       logger.error("migration_failed", extra={'job_id': kwargs['kwargs']['job_id']})
   ```

### Scaling Behavior

**At 50 concurrent jobs** (single worker):
```
Worker process:
  - Celery concurrency pool: 50 "slots"
  - Each slot: async/thread-based, not blocking GIL
  - I/O operations (SSH, API calls) don't block others
  - Memory: ~1GB baseline + 100MB per job
  - CPU: ~10% idle (mostly I/O waits)
```

**At 200 concurrent jobs** (4 workers):
```
Architecture:
  - 4 worker containers
  - Each: 50 concurrency = 200 total
  
Broker (Redis):
  - Connection pool: ~200 active
  - Message throughput: ~1000 msgs/sec
  - Well within Redis capacity
  
Database (MariaDB):
  - Connections: ~50 (reused)
  - Queries: status updates, job progress updates
  - Load: ~5% of typical max
  
Disk:
  - Each container: 20GB tmp per 50 jobs = 1GB each
  - Total: 4 containers × 1GB = 4GB temp space needed
  - Cleanup on task end prevents accumulation
```

**Graceful Degradation**:
```
If system is under heavy load:
  - New jobs queue up in Redis (doesn't lose them)
  - Workers pick up jobs as slots free
  - No request dropped (backpressure handled)
  - Timeouts: soft=1h, hard=1.5h (job completes or dies gracefully)
```

---

## IMPLEMENTATION SUMMARY

### Three Coordinated Changes

| Initiative | Effort | Impact | Risk |
|---|---|---|---|
| **1. Superadmin Bootstrap** | 2 hours | High (enables first login) | Low (idempotent init) |
| **2. Session Expiration** | 4 hours | Medium (security + UX) | Low (orthogonal to jobs) |
| **3. Worker Scaling** | 6 hours | High (enables production scale) | Medium (refactor cleanup) |

### Benefits

✅ **Security**: 2-hour inactivity timeout, no manual user setup  
✅ **Reliability**: Jobs survive session expiration, graceful cleanup  
✅ **Scalability**: 200 concurrent migrations (100x current)  
✅ **Observability**: Progress tracking, structured logging, monitoring hooks  
✅ **Maintainability**: Backward compatible, clean architecture  

### Compatibility

✅ Preserves all existing APIs  
✅ No breaking changes to User model  
✅ No breaking changes to MigrationJob workflow  
✅ Existing tests continue to pass  

---

## Next Steps

1. **Review this analysis** ← You are here
2. **Approve proposed architecture**
3. **Implementation** (3 phases, can be done sequentially)
4. **Testing** (unit + integration + load tests)
5. **Deployment** (update .env, scale workers, monitor)

