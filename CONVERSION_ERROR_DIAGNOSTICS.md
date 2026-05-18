# Conversion Error Diagnostics - Air-Gapped Environment Guide

## Overview

Enhanced error logging has been implemented to provide comprehensive diagnostics for virt-v2v conversion failures in air-gapped environments where direct database access may be limited.

## Changes Made

### 1. **Enhanced Logger Output**
When a virt-v2v conversion fails, the error log now includes:
- Full error message
- Return code
- First 5KB of stderr (contains the actual virt-v2v error)
- First 5KB of stdout (conversion execution context)

**Log Location**: Container logs visible via `docker logs vmigrate-conversion-worker-offline`

### 2. **Persistent Error Log Files**
Each conversion failure now generates a detailed error log file that:
- **Survives rollback**: Not deleted during job cleanup
- **Persists after DB deletion**: Available even if job is rolled back
- **Contains full diagnostic info**: Complete stderr/stdout output

**Location**: `/var/lib/vm-migrator/images/error_logs/job-{id}_{vm_name}_{timestamp}.error.log`

### 3. **File Persistence Strategy**
Unlike conversion artifacts which are cleaned during rollback, error logs are stored in a dedicated `error_logs/` directory that is **NOT** subject to cleanup. This ensures diagnostic information is preserved for analysis.

## Accessing Diagnostics in Air-Gapped Environment

### Option 1: Extract Error Log Files from Container

```bash
# List all error logs
docker cp vmigrate-conversion-worker-offline:/var/lib/vm-migrator/images/error_logs ./error_logs

# Or extract a specific job's error log
docker cp vmigrate-conversion-worker-offline:/var/lib/vm-migrator/images/error_logs/job-4_test_*.error.log ./job-4-error.log

# View the error log
cat ./job-4-error.log
```

### Option 2: Check Container Logs with Full Context

```bash
# Get logs filtered for conversion failures with stderr
docker logs vmigrate-conversion-worker-offline | grep -A 10 '"error":"virt-v2v'

# Or use jq if JSON logging is enabled
docker logs vmigrate-conversion-worker-offline | jq 'select(.message=="migration.start conversion_failed")'
```

### Option 3: Mount Shared Volume (Recommended for Air-Gapped)

Update your `docker-compose.offline.yml` to expose error logs:

```yaml
volumes:
  - vmigrator-images:/var/lib/vm-migrator/images
  - ./error-logs:/var/lib/vm-migrator/images/error_logs:ro  # Read-only bind mount
```

Then access locally:
```bash
ls -la ./error-logs/
cat ./error-logs/job-4_test_*.error.log
```

## Understanding virt-v2v Exit Codes

Common virt-v2v failure patterns in the error logs:

| Pattern | Cause | Solution |
|---------|-------|----------|
| `server does not support 'range'` | HTTP endpoint doesn't support byte ranges | Use VDDK transport with nbdkit |
| `cannot open plugin` | nbdkit VDDK plugin missing | Ensure nbdkit-vddk-plugin.so is installed |
| `unknown -i option` | Unsupported input method | Update virt-v2v to >= 2.1 |
| `invalid-credentials` | ESXi authentication failure | Verify ESXi credentials and thumbprint |
| `Connection refused` | ESXi unreachable | Check network connectivity and firewall |
| `Permission denied` | File/datastore access issues | Verify ESXi user has required permissions |

## Error Log File Format

Each error log contains:

```
CONVERSION ERROR LOG
====================
Job ID: 4
VM Name: test
Timestamp: 2026-05-18T11:29:55.326452+00:00
Error: virt-v2v failed with exit code 1

STDERR Output:
--------------
[Full stderr from virt-v2v, including specific error context]

STDOUT Output:
--------------
[Full stdout showing conversion progress and execution context]
```

## Integration with Offline Deployment

For offline Docker Compose deployments:

1. **Automatic Collection**: Error logs are written automatically on conversion failure
2. **No Database Required**: Diagnostics available even if DB is inaccessible
3. **Volume Mounting**: Add error-logs directory to your docker-compose for easy access
4. **Archiving**: Copy error-logs periodically for trend analysis

## Example Diagnostic Workflow for Air-Gapped Env

```bash
# 1. Run a migration job (job 4)
# Wait for failure...

# 2. Extract error log immediately after failure
docker cp vmigrate-conversion-worker-offline:/var/lib/vm-migrator/images/error_logs ./current-error-logs

# 3. Analyze the error
cat ./current-error-logs/job-4_test_*.error.log

# 4. Check container logs for additional context
docker logs vmigrate-conversion-worker-offline | grep "job_id.: 4" | tail -20

# 5. Based on the error, adjust configuration or debugging
# Example: If nbdkit plugin is missing, rebuild container with correct dependencies
```

## Previous Issue Resolution

**Problem**: Job 4 failed with `exit code 1` but only generic message was logged, making root-cause analysis impossible once database was rolled back.

**Solution**: Implemented two-tier logging:
1. Structured log entries with truncated stderr (visible in real-time)
2. Persistent error log files with full diagnostic output (available long-term)

This ensures that in an air-gapped environment where you may not have immediate database access, you can still diagnose conversion failures through container logs and error log files.

## Configuration Options

If you need to adjust error log truncation limits, set in your environment:

```bash
# Truncate stderr/stdout to N bytes in container logs (default: 5000)
export CONVERSION_LOG_TRUNCATE_BYTES=10000
```

Note: Error log files are **never truncated**; they contain the full output.

## Troubleshooting

**Q: Error logs directory is not being created**
A: Ensure `MIGRATION_OUTPUT_DIR` is writable by the worker process. Default: `/var/lib/vm-migrator/images`

**Q: Error log file contains "empty" for stderr**
A: Some errors occur before virt-v2v processes output (e.g., missing files). Check container logs for the full error context.

**Q: Need to delete old error logs**
A: Safe to delete files in `error_logs/` directory manually; they don't affect running conversions:
```bash
rm -rf /var/lib/vm-migrator/images/error_logs/job-*.error.log
```

## Next Steps for Continuous Improvement

1. **Monitor error patterns**: Regularly review error logs to identify recurring issues
2. **Implement alerting**: Write a script to monitor error_logs/ for new failures
3. **Enhance virt-v2v instrumentation**: Consider capturing additional context (environment vars, virt-v2v version, timing)
4. **Archive for compliance**: Store error logs with conversion metadata for audit trails
