# Multi-Endpoint Setup Guide

This system supports **multiple ESXi hosts** as migration sources and **multiple OpenStack deployments** as migration targets. Users can discover VMs from any ESXi endpoint and migrate them to the OpenStack environment of their choice.

## Architecture Overview

```
Multiple ESXi Hosts (VmwareEndpointSession)
    ↓
    ├─ ESXi 1 (192.168.x.x)
    ├─ ESXi 2 (192.168.x.x)
    └─ ESXi 3 (192.168.x.x)
    
        → Discover VMs
        → Create DiscoveredVM (linked to specific ESXi endpoint)
        → Create MigrationJob
        → User selects target OpenStack (OpenstackEndpointSession)
    
Multiple OpenStack Deployments (OpenstackEndpointSession)
    ↓
    ├─ OpenStack Dev
    ├─ OpenStack Prod
    └─ OpenStack DR
```

## 1. Register ESXi Endpoints

Register each ESXi host/vCenter that you want to discover VMs from.

### Via Django Shell

```bash
docker exec vmigrate-backend python manage.py shell
```

```python
from migrations.models import VmwareEndpointSession

# ESXi Host 1
VmwareEndpointSession.objects.create(
    label="ESXi Lab 1",
    host="192.168.72.172",
    port=443,
    username="root",
    password="YourESXiPassword1",
    insecure=True,
    datacenter="",
)

# ESXi Host 2
VmwareEndpointSession.objects.create(
    label="ESXi Lab 2",
    host="192.168.72.242",
    port=443,
    username="root",
    password="YourESXiPassword2",
    insecure=True,
    datacenter="",
)

# List all ESXi endpoints
for session in VmwareEndpointSession.objects.all():
    print(f"{session.id}: {session.label} ({session.host})")
```

### Via Django Admin

1. Go to `http://localhost/admin/`
2. Click **VmwareEndpointSession**
3. Click **Add VmwareEndpointSession**
4. Fill in:
   - **Label**: "ESXi Lab 1" (human-readable name)
   - **Host**: IP or hostname of ESXi/vCenter
   - **Port**: 443 (default)
   - **Username**: root or service account
   - **Password**: ESXi password
   - **Insecure**: ☑ (skip SSL verification)
   - **Datacenter**: (leave blank for ESXi, required for vCenter)
5. Click **Save**

## 2. Register OpenStack Endpoints

Register each OpenStack deployment as a migration target.

### Via Django Shell

```bash
docker exec vmigrate-backend python manage.py shell
```

```python
from migrations.models import OpenstackEndpointSession

# OpenStack Production
OpenstackEndpointSession.objects.create(
    label="OpenStack Prod",
    auth_url="http://192.168.1.100:5000/v3",
    username="admin",
    password="openstack_password",
    project_name="admin",
    user_domain_name="Default",
    project_domain_name="Default",
    region_name="RegionOne",
    verify=False,
)

# OpenStack Dev
OpenstackEndpointSession.objects.create(
    label="OpenStack Dev",
    auth_url="http://192.168.1.200:5000/v3",
    username="admin",
    password="dev_password",
    project_name="admin",
    user_domain_name="Default",
    project_domain_name="Default",
    region_name="RegionOne",
    verify=False,
)

# List all OpenStack endpoints
for session in OpenstackEndpointSession.objects.all():
    print(f"{session.id}: {session.label} ({session.project_name}@{session.auth_url})")
```

### Via Django Admin

1. Go to `http://localhost/admin/`
2. Click **OpenstackEndpointSession**
3. Click **Add OpenstackEndpointSession**
4. Fill in OpenStack auth details:
   - **Label**: "OpenStack Prod" (human-readable name)
   - **Auth URL**: Keystone endpoint (e.g., `http://192.168.1.100:5000/v3`)
   - **Username**: Service account or admin
   - **Password**: OpenStack password
   - **Project Name**: Project to deploy VMs into
   - **User Domain/Project Domain**: Typically "Default"
   - **Region Name**: "RegionOne" (or your region)
   - **Verify**: ☐ (uncheck to skip SSL verification)
5. Click **Save**

## 3. Discover VMs from Specific ESXi Endpoint

When discovering VMs, the system will ask which ESXi endpoint to connect to.

### Frontend Workflow
1. Go to **Discovery** → **New Discovery**
2. Select **ESXi Endpoint**: e.g., "ESXi Lab 1"
3. The system connects using that endpoint's credentials
4. Select VMs from that host

### Result
- `DiscoveredVM` objects are created
- Each `DiscoveredVM` is linked to the source `VmwareEndpointSession`
- VMs are labeled with their source: "ESXi Lab 1"

## 4. Create Migration Job and Select Target OpenStack

When creating a migration job for a `DiscoveredVM`:

### Frontend Workflow
1. Go to **Migrations** → **New Migration**
2. Select **Source VM**: e.g., "test-vm (from ESXi Lab 1)"
3. Select **Target OpenStack**: e.g., "OpenStack Prod"
4. Review precheck report
5. Start migration

### Backend Behavior
- Migration stores the selected endpoint session IDs in `metadata`:
  ```json
  {
    "selected_vmware_endpoint_session_id": 1,
    "selected_openstack_endpoint_session_id": 2
  }
  ```
- During conversion, the Celery worker uses the correct ESXi credentials from VmwareEndpointSession #1
- During upload/deployment, it uses OpenStack credentials from OpenstackEndpointSession #2

## 5. Test Endpoints

### Test ESXi Endpoint

```bash
docker exec vmigrate-backend python manage.py shell
```

```python
from migrations.models import VmwareEndpointSession
from migrations.openstack_client import test_vmware_connection

session = VmwareEndpointSession.objects.get(id=1)
result = test_vmware_connection(session)
print(f"Host: {session.host}")
print(f"Status: {result['success']}")
print(f"Message: {result['message']}")
```

### Test OpenStack Endpoint

```bash
docker exec vmigrate-backend python manage.py shell
```

```python
from migrations.models import OpenstackEndpointSession
from migrations.openstack_client import openstack_client_from_session

session = OpenstackEndpointSession.objects.get(id=2)
try:
    client = openstack_client_from_session(session)
    print(f"Project: {session.project_name}")
    print(f"Region: {session.region_name}")
    print(f"Connection: SUCCESS")
except Exception as e:
    print(f"Connection: FAILED - {e}")
```

## 6. Example: Current Issue (Job 6)

Your Job 6 failed because:
- **ESXi host used**: 192.168.72.242 (from VmwareEndpointSession)
- **Credentials**: Incorrect or endpoint doesn't exist

### Fix

1. **Find which ESXi endpoint was used**:
   ```bash
   docker exec vmigrate-backend python manage.py shell
   ```
   ```python
   from migrations.models import MigrationJob
   job = MigrationJob.objects.get(id=6)
   print(job.metadata)  # Shows selected_vmware_endpoint_session_id
   ```

2. **Check that endpoint's credentials**:
   ```python
   from migrations.models import VmwareEndpointSession
   endpoint = VmwareEndpointSession.objects.get(
       id=job.metadata['selected_vmware_endpoint_session_id']
   )
   print(f"Host: {endpoint.host}")
   print(f"Username: {endpoint.username}")
   # Password is encrypted, but you can view it via admin
   ```

3. **If credentials are wrong**, update them:
   ```python
   endpoint.password = "correct_password"
   endpoint.save()
   ```

4. **If endpoint doesn't exist**, create it:
   ```python
   VmwareEndpointSession.objects.create(
       label="ESXi 192.168.72.242",
       host="192.168.72.242",
       username="root",
       password="correct_password",
       insecure=True,
   )
   ```

5. **Retry the migration** from the UI

## 7. Environment Variables vs. Endpoints

- **`.env` variables** (`VMWARE_ESXI_HOST`, `VMWARE_ESXI_PASSWORD`): Fallback for local dev
- **Database endpoints** (`VmwareEndpointSession`, `OpenstackEndpointSession`): Used for production multi-endpoint setups
- **Migration metadata**: Points to specific endpoint session IDs

When a migration job is created:
1. If a VmwareEndpointSession is selected → use that endpoint's credentials
2. If no endpoint selected → fall back to `.env` values

## 8. Troubleshooting Multi-Endpoint Issues

| Issue | Cause | Fix |
|-------|-------|-----|
| "Incorrect username or password" | Wrong credentials in endpoint | Update VmwareEndpointSession.password in admin |
| "Connection refused" | ESXi host offline or unreachable | Test connectivity: `curl -k https://HOST:PORT/` |
| "HTTP range requests not supported" | ESXi HTTP layer issue | Update ESXi or use different transport method |
| VM discovered from wrong host | Endpoint selection error | Check migration metadata: `selected_vmware_endpoint_session_id` |
| OpenStack upload fails | Wrong OpenStack endpoint selected | Verify OpenstackEndpointSession auth_url and credentials |

## Next Steps

1. **Register your ESXi hosts**:
   - ESXi 192.168.72.172 with correct password
   - ESXi 192.168.72.242 with correct password

2. **Register your OpenStack endpoint(s)**:
   - OpenStack deployment with auth URL, credentials, and region

3. **Re-run Job 6 discovery** (or create Job 7):
   - Select the correct ESXi endpoint
   - Verify the credentials work
   - Select the target OpenStack environment

4. **Test conversions** with valid ESXi credentials
