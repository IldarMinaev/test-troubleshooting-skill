---
name: postgresql-backup-check
description: Check backup health — backup daemon status, pgBackRest info, backup schedules, WAL archiver, retention
---

# PostgreSQL Backup Check

## Purpose

Verify the health of PostgreSQL backup infrastructure: backup daemon status, pgBackRest backup history and integrity, WAL archiving, backup schedules, and retention policies.

## Prerequisites

- `kubectl` with access to the target cluster
- Namespace where PostgreSQL is deployed (default: `postgres`)
- `patroni-services` Helm release installed with backup daemon enabled

See [pgskipper-architecture.md](../_common/pgskipper-architecture.md) for broader context on component names and namespace conventions.

> **🔒 SECURITY REQUIRED**: Before executing commands, read [SECURITY.md](../_common/SECURITY.md) for credential handling patterns. Never expose passwords in command output.

## Context: Verify Kubernetes Access

```bash
kubectl config current-context
kubectl get namespace <NAMESPACE>
```

## Step 1: Check Backup Daemon Deployment

```bash
kubectl get deployment -n <NAMESPACE> postgres-backup-daemon
kubectl get pods -n <NAMESPACE> -l app=postgres-backup-daemon -o wide
```

**Interpret**: Pod must be `Running` with all containers ready. If missing, backup daemon was not installed (check `patroni-services` Helm values).

If not running:
```bash
kubectl describe pod -n <NAMESPACE> -l app=postgres-backup-daemon
kubectl logs -n <NAMESPACE> -l app=postgres-backup-daemon --tail=50
```

## Step 2: Check Backup Daemon API

```bash
# Port-forward to backup daemon
kubectl port-forward -n <NAMESPACE> svc/postgres-backup-daemon 8080:8080 &
PF_PID=$!
sleep 2

# Health check
curl -s http://localhost:8080/health
```

## Step 3: Check pgBackRest from Inside Patroni Pod

```bash
MASTER_POD=$(kubectl get pods -n <NAMESPACE> -l pgtype=master -o jsonpath='{.items[0].metadata.name}')

# pgBackRest info — shows backup history
kubectl exec -n <NAMESPACE> $MASTER_POD -c pgbackrest-sidecar -- pgbackrest info 2>/dev/null || \
  kubectl exec -n <NAMESPACE> $MASTER_POD -- pgbackrest info
```

**Interpret**: Look for:
- **Full backup**: Should exist. This is the base backup.
- **Incremental/Differential backups**: Should be recent (within schedule)
- **Backup status**: `ok` = good, `error` = failed
- **Backup age**: Full backup should not be too old (depends on retention policy)

```bash
# Detailed backup info with JSON output
kubectl exec -n <NAMESPACE> $MASTER_POD -c pgbackrest-sidecar -- pgbackrest info --output=json 2>/dev/null | jq '.[0].backup[] | {label, type, timestamp_start: (.timestamp.start | todate), timestamp_stop: (.timestamp.stop | todate), database_size: .info.size, backup_size: .info.delta}'
```

## Step 4: Check WAL Archiving and Replication Slots (SQL)

Run the replication SQL file — covers WAL archive status, replication slots, inactive slot warnings, and WAL accumulation:

```bash
kubectl exec -i -n <NAMESPACE> $MASTER_POD -- env PGPASSWORD="$(kubectl get secret -n <NAMESPACE> postgres-credentials -o jsonpath='{.data.password}' | base64 -d)" psql -U postgres -d postgres -f /dev/stdin < skills/_sql/replication.sql
```

**Focus on**:
- `pg_stat_archiver`: `failed_count` > 0 with recent `last_failed_time` = active archiving problem; `last_archived_time` very old = archiving stuck
- Replication slots: inactive slots hold WAL and can cause disk pressure
- WAL statistics: high WAL generation rate with archive failures = storage risk

## Step 5: Check Archive Mode Configuration

```bash
kubectl exec -n <NAMESPACE> $MASTER_POD -- env PGPASSWORD="$(kubectl get secret -n <NAMESPACE> postgres-credentials -o jsonpath='{.data.password}' | base64 -d)" psql -U postgres -d postgres -c "
SELECT name, setting FROM pg_settings
WHERE name IN ('archive_mode', 'archive_command', 'archive_timeout')
ORDER BY name;
"
```

**Interpret**:
- `archive_mode` should be `on`
- `archive_command` should point to pgBackRest or other archive tool
- `archive_timeout` defines maximum time between WAL archives

## Step 6: Check Backup Schedules (CronJob or Daemon Config)

```bash
# Check for backup CronJobs
kubectl get cronjobs -n <NAMESPACE> | grep -i backup

# Check backup daemon configuration
kubectl get configmap -n <NAMESPACE> -l app=postgres-backup-daemon -o yaml
```

## Step 7: Check Storage and WAL Accumulation (SQL)

Run the storage SQL file — covers WAL directory size, database sizes, and temporary files alongside disk space metrics:

```bash
kubectl exec -i -n <NAMESPACE> $MASTER_POD -- env PGPASSWORD="$(kubectl get secret -n <NAMESPACE> postgres-credentials -o jsonpath='{.data.password}' | base64 -d)" psql -U postgres -d postgres -f /dev/stdin < skills/_sql/storage.sql
```

**Focus on**:
- WAL directory size and file count — large values with archive failures = storage risk
- Overall data directory size — helps assess whether backup storage is adequate
- If WAL is accumulating, cross-reference archive failures (Step 4) and inactive slots

## Cleanup

```bash
kill $PF_PID 2>/dev/null
```

## Summary Report

| Check | Status | Details |
|-------|--------|---------|
| Backup daemon | OK/CRITICAL | Running / Not running / Not installed |
| Backup daemon API | OK/CRITICAL | Healthy / Unreachable |
| Last full backup | OK/WARNING/CRITICAL | Age and status |
| Last incremental | OK/WARNING | Age and status |
| WAL archiving | OK/WARNING/CRITICAL | Active / Failures detected |
| Archive mode | OK/CRITICAL | On / Off |
| WAL accumulation | OK/WARNING | N files, X total size |
| Backup schedule | OK/WARNING | Configured / Missing |

## Common Issues and Remediation

1. **Backup daemon not installed**: Install via `patroni-services` Helm chart with `backupDaemon.install=true`
2. **pgBackRest info shows no backups**: Initial full backup never taken. Trigger manually via backup daemon API.
3. **WAL archive failures**: Check `archive_command`, pgBackRest configuration, and repository storage availability.
4. **WAL accumulation**: Inactive replication slots or archive failures preventing WAL cleanup. Drop unused slots (with user approval).
5. **Old full backup**: Retention policy may be too loose, or backup schedule is missing/failing.
6. **pgbackrest-sidecar container missing**: Check `patroni-services` Helm values for backup configuration.
