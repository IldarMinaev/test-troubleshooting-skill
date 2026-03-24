---
name: postgresql-storage-check
description: Check PVC capacity, disk usage inside pods, database/table sizes, WAL accumulation, replication slot bloat, table bloat
---

# PostgreSQL Storage Check

## Purpose

Diagnose storage health: PVC capacity and usage, disk usage inside Patroni pods, database/table/index sizes, WAL accumulation, inactive replication slot WAL retention, and table bloat estimation.

## Prerequisites

- `kubectl` with exec permissions
- Namespace where PostgreSQL is deployed (default: `postgres`)

See [pgskipper-architecture.md](../_common/pgskipper-architecture.md) for broader context. Note: data directory is discovered dynamically via `SHOW data_directory` in Step 2 — no need to look up the path manually.

> **🔒 SECURITY REQUIRED**: Before executing commands, read [SECURITY.md](../_common/SECURITY.md) for credential handling patterns. Never expose passwords in command output.

## Context: Verify Kubernetes Access and Find Pods

```bash
kubectl config current-context
MASTER_POD=$(kubectl get pods -n <NAMESPACE> -l pgtype=master -o jsonpath='{.items[0].metadata.name}')

# Note: Do NOT retrieve password separately - use inline retrieval in each command (see examples below)
```

## Step 1: PVC Status and Capacity

```bash
kubectl get pvc -n <NAMESPACE> -l app=patroni -o wide
```

**Interpret**: All PVCs should be `Bound`. Check CAPACITY column for allocated size.

## Step 2: Disk Usage Inside Pods

First, discover the actual data directory (varies by installation):

```bash
DATA_DIR=$(kubectl exec -n <NAMESPACE> $MASTER_POD -- env PGPASSWORD="$(kubectl get secret -n <NAMESPACE> postgres-credentials -o jsonpath='{.data.password}' | base64 -d)" psql -U postgres -d postgres -tAc "SHOW data_directory;")
echo "Data directory: $DATA_DIR"
```

```bash
# Check all Patroni pods
for POD in $(kubectl get pods -n <NAMESPACE> -l app=patroni -o jsonpath='{.items[*].metadata.name}'); do
    echo "=== $POD ==="
    kubectl exec -n <NAMESPACE> $POD -- df -h "$DATA_DIR"
done
```

**Interpret**:
- Usage > 85% = WARNING
- Usage > 95% = CRITICAL — PostgreSQL will refuse writes when disk is full
- Check for unexpected growth patterns
- If `df` fails with "No such file or directory", the data directory path may differ per node — check each pod individually with `SHOW data_directory`

Detailed breakdown:
```bash
kubectl exec -n <NAMESPACE> $MASTER_POD -- du -sh "$DATA_DIR/pg_wal/" 2>/dev/null
kubectl exec -n <NAMESPACE> $MASTER_POD -- du -sh "$DATA_DIR/base/" 2>/dev/null
kubectl exec -n <NAMESPACE> $MASTER_POD -- du -sh "$DATA_DIR/pg_tblspc/" 2>/dev/null
```

## Step 3: Database and Table Sizes (SQL)

Run the storage SQL file (path relative to repo root):

```bash
kubectl exec -i -n <NAMESPACE> $MASTER_POD -- env PGPASSWORD="$(kubectl get secret -n <NAMESPACE> postgres-credentials -o jsonpath='{.data.password}' | base64 -d)" psql -U postgres -d postgres -f /dev/stdin < skills/_sql/storage.sql
```

Or check key metrics:

```bash
# Database sizes
kubectl exec -n <NAMESPACE> $MASTER_POD -- env PGPASSWORD="$(kubectl get secret -n <NAMESPACE> postgres-credentials -o jsonpath='{.data.password}' | base64 -d)" psql -U postgres -d postgres -c "
SELECT datname, pg_size_pretty(pg_database_size(datname)) AS size
FROM pg_database WHERE datallowconn ORDER BY pg_database_size(datname) DESC;
"

# Top 10 largest tables
kubectl exec -n <NAMESPACE> $MASTER_POD -- env PGPASSWORD="$(kubectl get secret -n <NAMESPACE> postgres-credentials -o jsonpath='{.data.password}' | base64 -d)" psql -U postgres -d postgres -c "
SELECT schemaname, relname,
    pg_size_pretty(pg_total_relation_size(schemaname || '.' || relname)) AS total,
    pg_size_pretty(pg_relation_size(schemaname || '.' || relname)) AS table_only,
    n_live_tup AS rows
FROM pg_stat_user_tables
ORDER BY pg_total_relation_size(schemaname || '.' || relname) DESC LIMIT 10;
"
```

## Step 4: WAL Accumulation

```bash
kubectl exec -n <NAMESPACE> $MASTER_POD -- env PGPASSWORD="$(kubectl get secret -n <NAMESPACE> postgres-credentials -o jsonpath='{.data.password}' | base64 -d)" psql -U postgres -d postgres -c "
SELECT
    (SELECT count(*) FROM pg_ls_waldir()) AS wal_files,
    (SELECT pg_size_pretty(sum(size)) FROM pg_ls_waldir()) AS total_wal_size,
    (SELECT setting FROM pg_settings WHERE name = 'max_wal_size') AS max_wal_size,
    (SELECT setting FROM pg_settings WHERE name = 'min_wal_size') AS min_wal_size;
"
```

**Interpret**:
- WAL size up to 2x `max_wal_size` is normal during high write load (checkpoints may lag)
- WAL size 2-5x `max_wal_size` = **WARNING** — investigate causes below
- WAL size > 5x `max_wal_size` = **CRITICAL** — WAL is accumulating unchecked, disk full risk
- If WAL is above expected range, check these causes in order:
  1. `wal_keep_segments` (PG < 13) or `wal_keep_size` (PG 13+) intentionally retains WAL for replicas — check Patroni config with `patronictl show-config`. This is by design, not an error.
  2. Inactive replication slots (Step 5) — the #1 unintentional cause of WAL bloat
  3. Failed WAL archiving (`archive_command` returning errors) prevents WAL cleanup
- WAL within expected range of `wal_keep_size` = OK even if above `max_wal_size`

## Step 5: Inactive Replication Slot WAL Bloat

```bash
kubectl exec -n <NAMESPACE> $MASTER_POD -- env PGPASSWORD="$(kubectl get secret -n <NAMESPACE> postgres-credentials -o jsonpath='{.data.password}' | base64 -d)" psql -U postgres -d postgres -c "
SELECT
    slot_name,
    slot_type,
    active,
    pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS wal_retained,
    pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) AS wal_retained_bytes
FROM pg_replication_slots
WHERE NOT pg_is_in_recovery()
ORDER BY wal_retained_bytes DESC;
"
```

**Interpret**:
- Inactive slots (`active = false`) with large `wal_retained` are the #1 cause of WAL bloat
- Active slots with large retained WAL indicate slow replicas

**Remediation** (with user approval):
```sql
-- Drop an inactive slot
SELECT pg_drop_replication_slot('<slot_name>');
```

## Step 6: Table Bloat Estimation

Run the bloat estimation SQL file (path relative to repo root):

```bash
kubectl exec -i -n <NAMESPACE> $MASTER_POD -- env PGPASSWORD="$(kubectl get secret -n <NAMESPACE> postgres-credentials -o jsonpath='{.data.password}' | base64 -d)" psql -U postgres -d postgres -f /dev/stdin < skills/_sql/bloat_estimation.sql
```

Or quick check:

```bash
kubectl exec -n <NAMESPACE> $MASTER_POD -- env PGPASSWORD="$(kubectl get secret -n <NAMESPACE> postgres-credentials -o jsonpath='{.data.password}' | base64 -d)" psql -U postgres -d postgres -c "
SELECT schemaname, relname,
    n_dead_tup, n_live_tup,
    round(n_dead_tup::numeric * 100 / NULLIF(n_live_tup, 0), 2) AS dead_pct,
    pg_size_pretty(pg_total_relation_size(schemaname || '.' || relname)) AS size
FROM pg_stat_user_tables
WHERE n_dead_tup > 10000
ORDER BY n_dead_tup DESC LIMIT 10;
"
```

## Step 7: Temp Files

```bash
kubectl exec -n <NAMESPACE> $MASTER_POD -- env PGPASSWORD="$(kubectl get secret -n <NAMESPACE> postgres-credentials -o jsonpath='{.data.password}' | base64 -d)" psql -U postgres -d postgres -c "
SELECT datname, temp_files, pg_size_pretty(temp_bytes) AS temp_size
FROM pg_stat_database WHERE temp_files > 0 ORDER BY temp_bytes DESC;
"
```

**Interpret**: Large temp files indicate queries doing on-disk sorts/hashes. Increase `work_mem` or optimize queries.

## Summary Report

| Check | Status | Details |
|-------|--------|---------|
| PVC status | OK/CRITICAL | All bound / Pending |
| Disk usage | OK/WARNING/CRITICAL | X% used on each pod |
| Database sizes | INFO | Largest: X (size) |
| WAL accumulation | OK/WARNING/CRITICAL | N files, X total |
| Inactive slot WAL | OK/WARNING/CRITICAL | X WAL retained by inactive slots |
| Table bloat | OK/WARNING/CRITICAL | Top table: X% dead tuples |
| Temp files | OK/WARNING | X temp data generated |

## Common Issues and Remediation

1. **Disk > 95%**: Emergency — identify largest consumers (WAL, tables, temp files). May need to drop inactive replication slots, VACUUM, or expand PVC.
2. **WAL accumulation**: Drop inactive replication slots. Fix WAL archive failures. Check `max_wal_size` setting.
3. **High table bloat**: Run `VACUUM ANALYZE` on affected tables. Tune autovacuum parameters.
4. **PVC Pending**: StorageClass or PV provisioner issue. Check with `pgskipper-check`.
5. **Large temp files**: Increase `work_mem`. Optimize queries with large sorts/hash joins.
6. **Database unexpectedly large**: Check for large tables, TOAST data, or excessive indexes.
