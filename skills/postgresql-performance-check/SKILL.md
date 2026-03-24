---
name: postgresql-performance-check
description: Analyze database load — slow queries, bad clients, lock contention, cache efficiency, vacuum health
---

# PostgreSQL Performance Check

## Purpose

Identify performance bottlenecks in a PostgreSQL database: slow queries, high load, lock contention, poor cache utilization, connection saturation, and vacuum issues.

## Prerequisites

- `kubectl` with exec permissions
- Namespace where PostgreSQL is deployed (default: `postgres`)
- `pg_stat_statements` extension (optional, for query-level stats)

See [postgresql-sql-runner skill](../postgresql-sql-runner/SKILL.md) for SQL execution patterns.

> **🔒 SECURITY REQUIRED**: Before executing commands, read [SECURITY.md](../_common/SECURITY.md) for credential handling patterns. Never expose passwords in command output.

## Context: Verify Kubernetes Access and Find Master

```bash
# Find the master pod
kubectl config current-context
MASTER_POD=$(kubectl get pods -n <NAMESPACE> -l pgtype=master -o jsonpath='{.items[0].metadata.name}')

# Note: Do NOT retrieve password separately - use inline retrieval in each command (see examples below)
```

## Step 1: Comprehensive Performance Overview (SQL)

Run the performance SQL file — covers slow query analysis (pg_stat_statements), active queries, connection state summary, cache hit ratio, table I/O statistics, unused indexes, vacuum health, and transaction throughput:

```bash
kubectl exec -i -n <NAMESPACE> $MASTER_POD -- env PGPASSWORD="$(kubectl get secret -n <NAMESPACE> postgres-credentials -o jsonpath='{.data.password}' | base64 -d)" psql -U postgres -d postgres -f /dev/stdin < skills/_sql/performance.sql
```

Review the output before proceeding. If the overview reveals a specific area of concern (locking, cache, vacuum), use the targeted steps below for deeper investigation.

## Step 2: Active Query State (Targeted)

```bash
kubectl exec -n <NAMESPACE> $MASTER_POD -- env PGPASSWORD="$(kubectl get secret -n <NAMESPACE> postgres-credentials -o jsonpath='{.data.password}' | base64 -d)" psql -U postgres -d postgres -c "
SELECT
    count(*) FILTER (WHERE state = 'active') AS active,
    count(*) FILTER (WHERE state = 'idle') AS idle,
    count(*) FILTER (WHERE state = 'idle in transaction') AS idle_in_txn,
    count(*) FILTER (WHERE wait_event_type = 'Lock') AS waiting_on_lock,
    count(*) AS total
FROM pg_stat_activity
WHERE pid <> pg_backend_pid() AND datname IS NOT NULL;
"
```

**Interpret**:
- High `active` count relative to CPU cores = overloaded
- `idle_in_txn` > 0 = potential connection leak / application issue
- `waiting_on_lock` > 0 = lock contention

## Step 3: Slow / Long-Running Queries (Targeted)

```bash
kubectl exec -n <NAMESPACE> $MASTER_POD -- env PGPASSWORD="$(kubectl get secret -n <NAMESPACE> postgres-credentials -o jsonpath='{.data.password}' | base64 -d)" psql -U postgres -d postgres -c "
SELECT
    pid,
    usename,
    application_name,
    now() - query_start AS duration,
    wait_event_type,
    wait_event,
    state,
    LEFT(query, 200) AS query_preview
FROM pg_stat_activity
WHERE state = 'active'
  AND now() - query_start > interval '10 seconds'
  AND pid <> pg_backend_pid()
ORDER BY duration DESC;
"
```

**Remediation**: For queries running > 5 minutes, consider:
- Optimizing the query (add indexes, rewrite)
- `SELECT pg_cancel_backend(<pid>);` to cancel
- `SELECT pg_terminate_backend(<pid>);` to terminate (with user approval)

## Step 4: Top Slow Queries by Total Time (pg_stat_statements)

First, check if the extension is available:

```bash
kubectl exec -n <NAMESPACE> $MASTER_POD -- env PGPASSWORD="$(kubectl get secret -n <NAMESPACE> postgres-credentials -o jsonpath='{.data.password}' | base64 -d)" psql -U postgres -d postgres -tAc "SELECT 1 FROM pg_extension WHERE extname = 'pg_stat_statements';"
```

If empty (no output), `pg_stat_statements` is not installed — skip this step. If `1`, proceed:

```bash
kubectl exec -n <NAMESPACE> $MASTER_POD -- env PGPASSWORD="$(kubectl get secret -n <NAMESPACE> postgres-credentials -o jsonpath='{.data.password}' | base64 -d)" psql -U postgres -d postgres -c "
SELECT
    queryid,
    LEFT(query, 100) AS query_preview,
    calls,
    round(total_exec_time::numeric, 2) AS total_ms,
    round(mean_exec_time::numeric, 2) AS mean_ms,
    rows,
    round(100.0 * shared_blks_hit / NULLIF(shared_blks_hit + shared_blks_read, 0), 2) AS cache_hit_pct
FROM pg_stat_statements
ORDER BY total_exec_time DESC
LIMIT 15;
"
```

## Step 5: Lock Contention

Run the locks SQL file for comprehensive lock analysis (preferred — covers lock trees, advisory locks, and deadlock-prone patterns):

```bash
kubectl exec -i -n <NAMESPACE> $MASTER_POD -- env PGPASSWORD="$(kubectl get secret -n <NAMESPACE> postgres-credentials -o jsonpath='{.data.password}' | base64 -d)" psql -U postgres -d postgres -f /dev/stdin < skills/_sql/locks.sql
```

## Step 6: Cache Hit Ratio (Targeted)

```bash
kubectl exec -n <NAMESPACE> $MASTER_POD -- env PGPASSWORD="$(kubectl get secret -n <NAMESPACE> postgres-credentials -o jsonpath='{.data.password}' | base64 -d)" psql -U postgres -d postgres -c "
SELECT
    datname,
    round(100.0 * blks_hit / NULLIF(blks_hit + blks_read, 0), 2) AS cache_hit_pct
FROM pg_stat_database
WHERE datname NOT IN ('template0', 'template1')
ORDER BY pg_database_size(datname) DESC;
"
```

**Interpret**:
- \> 99% = excellent
- 95-99% = good
- < 95% = may need more shared_buffers or queries are scanning too much data

## Step 7: Bad Clients (Connection Abusers)

```bash
kubectl exec -n <NAMESPACE> $MASTER_POD -- env PGPASSWORD="$(kubectl get secret -n <NAMESPACE> postgres-credentials -o jsonpath='{.data.password}' | base64 -d)" psql -U postgres -d postgres -c "
SELECT
    application_name,
    client_addr,
    count(*) AS connections,
    count(*) FILTER (WHERE state = 'idle in transaction') AS idle_in_txn,
    count(*) FILTER (WHERE state = 'idle' AND now() - state_change > interval '1 hour') AS long_idle
FROM pg_stat_activity
WHERE datname IS NOT NULL AND pid <> pg_backend_pid()
GROUP BY application_name, client_addr
HAVING count(*) > 5
ORDER BY connections DESC;
"
```

**Interpret**: Clients with many `idle_in_txn` or `long_idle` connections are leaking.

## Step 8: Vacuum Health (Targeted)

```bash
kubectl exec -n <NAMESPACE> $MASTER_POD -- env PGPASSWORD="$(kubectl get secret -n <NAMESPACE> postgres-credentials -o jsonpath='{.data.password}' | base64 -d)" psql -U postgres -d postgres -c "
SELECT
    schemaname,
    relname,
    n_dead_tup,
    n_live_tup,
    round(n_dead_tup::numeric * 100 / NULLIF(n_live_tup, 0), 2) AS dead_pct,
    last_autovacuum,
    autovacuum_count
FROM pg_stat_user_tables
WHERE n_dead_tup > 1000
ORDER BY n_dead_tup DESC
LIMIT 15;
"
```

Also check for empty-but-large tables (data deleted without VACUUM FULL):

```bash
kubectl exec -n <NAMESPACE> $MASTER_POD -- env PGPASSWORD="$(kubectl get secret -n <NAMESPACE> postgres-credentials -o jsonpath='{.data.password}' | base64 -d)" psql -U postgres -d postgres -c "
SELECT schemaname, relname,
    pg_size_pretty(pg_total_relation_size(schemaname || '.' || relname)) AS total_size,
    n_live_tup, n_dead_tup
FROM pg_stat_user_tables
WHERE pg_total_relation_size(schemaname || '.' || relname) > 10485760
  AND n_live_tup = 0
ORDER BY pg_total_relation_size(schemaname || '.' || relname) DESC;
"
```

**Interpret**: Tables with significant size but 0 rows indicate all data was deleted but space was not reclaimed. Regular VACUUM cannot reclaim this space — requires `VACUUM FULL` (takes exclusive lock) or `pg_repack`.

## Multi-database note

> **Important**: Steps 5-7 query table-level stats which are per-database. The checks above only cover the `postgres` database. For a complete assessment, list application databases and repeat table-level checks for each:
> ```bash
> kubectl exec -n <NAMESPACE> $MASTER_POD -- env PGPASSWORD="$(kubectl get secret -n <NAMESPACE> postgres-credentials -o jsonpath='{.data.password}' | base64 -d)" psql -U postgres -d postgres -tAc "
> SELECT datname FROM pg_database WHERE datallowconn AND datname NOT IN ('template0','template1','postgres');
> "
> ```
> Then re-run Steps 5-7 with `-d <dbname>` for each application database.

## Summary Report

| Check | Status | Details |
|-------|--------|---------|
| Active queries | OK/WARNING/CRITICAL | N active, N waiting on locks |
| Long-running queries | OK/WARNING | N queries > 5 min |
| Slow queries (top) | INFO | Top query: X ms mean |
| Lock contention | OK/WARNING/CRITICAL | N blocked queries |
| Cache hit ratio | OK/WARNING | X% overall |
| Connection abusers | OK/WARNING | Top client: N connections |
| Idle in transaction | OK/WARNING | N idle-in-txn connections |
| Dead tuples | OK/WARNING/CRITICAL | Top table: X% dead |
| Autovacuum | OK/WARNING | N tables overdue |

## Common Issues and Remediation

1. **Slow queries**: Check `EXPLAIN ANALYZE`, add missing indexes, rewrite sequential scans. Run `skills/_sql/memory_intensive_queries.sql` to find queries spilling to disk (temp file usage) — candidates for `work_mem` tuning.
2. **Lock contention**: Identify the blocking query, consider killing it (with user approval)
3. **Low cache hit ratio**: Increase `shared_buffers`, optimize queries to reduce I/O
4. **Connection leaks**: Application needs connection pool fixes. Immediate: kill idle-in-txn connections > 1 hour
5. **High dead tuples**: Autovacuum may be throttled. Check `autovacuum_max_workers`, `autovacuum_vacuum_scale_factor`
6. **XID wraparound approaching**: Emergency VACUUM FREEZE needed
