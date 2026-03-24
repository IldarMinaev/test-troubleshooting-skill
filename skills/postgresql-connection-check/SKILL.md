---
name: postgresql-connection-check
description: Check PgBouncer (connection-pooler) health, pool stats, max_connections usage, connection leak detection, service endpoints
---

# PostgreSQL Connection Check

## Purpose

Diagnose connection-layer health: PgBouncer (connection-pooler) status, pool utilization, PostgreSQL max_connections usage, connection leaks (idle-in-transaction), and service endpoint verification.

## Prerequisites

- `kubectl` with exec permissions
- Namespace where PostgreSQL is deployed (default: `postgres`)

See [pgskipper-architecture.md](../_common/pgskipper-architecture.md) for broader context on component names and namespace conventions.

> **🔒 SECURITY REQUIRED**: Before executing commands, read [SECURITY.md](../_common/SECURITY.md) for credential handling patterns. Never expose passwords in command output.

## Context: Verify Kubernetes Access and Find Pods

```bash
kubectl config current-context
MASTER_POD=$(kubectl get pods -n <NAMESPACE> -l pgtype=master -o jsonpath='{.items[0].metadata.name}')

# Note: Do NOT retrieve password separately - use inline retrieval in each command (see examples below)
```

## Step 1: Check PgBouncer (connection-pooler) Deployment

```bash
kubectl get deployment -n <NAMESPACE> connection-pooler
kubectl get pods -n <NAMESPACE> -l app=connection-pooler -o wide
```

**Interpret**: Pod must be `Running`. If missing, PgBouncer is not deployed (may be by design or misconfigured).

If no `connection-pooler` deployment or pods are found, PgBouncer is not deployed. **Skip Step 2** and proceed to Step 3. Note this in the summary as "PgBouncer: N/A — not deployed".

If pods exist but are not running:
```bash
kubectl describe pod -n <NAMESPACE> -l app=connection-pooler
kubectl logs -n <NAMESPACE> -l app=connection-pooler --tail=50
```

## Step 2: Check PgBouncer Stats

Connect to PgBouncer admin console:

```bash
POOLER_POD=$(kubectl get pods -n <NAMESPACE> -l app=connection-pooler -o jsonpath='{.items[0].metadata.name}')

# Pool stats
kubectl exec -n <NAMESPACE> $POOLER_POD -- env PGPASSWORD="$(kubectl get secret -n <NAMESPACE> postgres-credentials -o jsonpath='{.data.password}' | base64 -d)" psql -U postgres -p 6432 -d pgbouncer -c "SHOW POOLS;"

# Client connections
kubectl exec -n <NAMESPACE> $POOLER_POD -- env PGPASSWORD="$(kubectl get secret -n <NAMESPACE> postgres-credentials -o jsonpath='{.data.password}' | base64 -d)" psql -U postgres -p 6432 -d pgbouncer -c "SHOW CLIENTS;"

# Server connections
kubectl exec -n <NAMESPACE> $POOLER_POD -- env PGPASSWORD="$(kubectl get secret -n <NAMESPACE> postgres-credentials -o jsonpath='{.data.password}' | base64 -d)" psql -U postgres -p 6432 -d pgbouncer -c "SHOW SERVERS;"

# General stats
kubectl exec -n <NAMESPACE> $POOLER_POD -- env PGPASSWORD="$(kubectl get secret -n <NAMESPACE> postgres-credentials -o jsonpath='{.data.password}' | base64 -d)" psql -U postgres -p 6432 -d pgbouncer -c "SHOW STATS;"

# PgBouncer config
kubectl exec -n <NAMESPACE> $POOLER_POD -- env PGPASSWORD="$(kubectl get secret -n <NAMESPACE> postgres-credentials -o jsonpath='{.data.password}' | base64 -d)" psql -U postgres -p 6432 -d pgbouncer -c "SHOW CONFIG;" | grep -E 'pool_mode|max_client_conn|default_pool_size|min_pool_size|reserve_pool_size'
```

**Interpret SHOW POOLS**:
- `cl_active` / `cl_waiting`: client connections active vs waiting for server connection
- `sv_active` / `sv_idle`: server (PostgreSQL) connections active vs idle
- `cl_waiting` > 0 = clients are queued — pool may be too small

## Step 3: Check PostgreSQL max_connections Usage

Run the connections SQL file (path relative to repo root):

```bash
kubectl exec -i -n <NAMESPACE> $MASTER_POD -- env PGPASSWORD="$(kubectl get secret -n <NAMESPACE> postgres-credentials -o jsonpath='{.data.password}' | base64 -d)" psql -U postgres -d postgres -f /dev/stdin < skills/_sql/connections.sql
```

Or check key metrics:

```bash
kubectl exec -n <NAMESPACE> $MASTER_POD -- env PGPASSWORD="$(kubectl get secret -n <NAMESPACE> postgres-credentials -o jsonpath='{.data.password}' | base64 -d)" psql -U postgres -d postgres -c "
SELECT
    (SELECT count(*) FROM pg_stat_activity WHERE datname IS NOT NULL) AS current,
    (SELECT setting::int FROM pg_settings WHERE name = 'max_connections') AS max,
    round(100.0 * (SELECT count(*) FROM pg_stat_activity WHERE datname IS NOT NULL) /
        (SELECT setting::int FROM pg_settings WHERE name = 'max_connections'), 1) AS pct,
    (SELECT count(*) FROM pg_stat_activity WHERE state = 'idle in transaction') AS idle_in_txn,
    (SELECT count(*) FROM pg_stat_activity WHERE state = 'idle' AND now() - state_change > interval '1 hour') AS stale_idle;
"
```

**Interpret**:
- pct > 80% = WARNING, > 90% = CRITICAL
- `idle_in_txn` > 0 = potential leak
- `stale_idle` = connections that should probably be closed

## Step 4: Connection Leak Detection

```bash
kubectl exec -n <NAMESPACE> $MASTER_POD -- env PGPASSWORD="$(kubectl get secret -n <NAMESPACE> postgres-credentials -o jsonpath='{.data.password}' | base64 -d)" psql -U postgres -d postgres -c "
SELECT
    application_name,
    client_addr,
    count(*) AS total,
    count(*) FILTER (WHERE state = 'idle in transaction') AS idle_in_txn,
    count(*) FILTER (WHERE state = 'idle' AND now() - state_change > interval '30 minutes') AS stale_idle,
    max(now() - state_change) FILTER (WHERE state = 'idle in transaction') AS max_idle_txn_duration
FROM pg_stat_activity
WHERE datname IS NOT NULL AND pid <> pg_backend_pid()
GROUP BY application_name, client_addr
HAVING count(*) FILTER (WHERE state = 'idle in transaction') > 0
    OR count(*) FILTER (WHERE state = 'idle' AND now() - state_change > interval '30 minutes') > 3
ORDER BY idle_in_txn DESC, stale_idle DESC;
"
```

**Interpret**: Applications with `idle_in_txn` or many `stale_idle` connections are leaking. The `application_name` identifies the offending service.

## Step 5: Service Endpoint Verification

```bash
# All PostgreSQL-related services
kubectl get svc -n <NAMESPACE> | grep pg-

# Endpoints (should have IPs)
kubectl get endpoints -n <NAMESPACE> | grep pg-
```

**Interpret**:
- `pg-<cluster>` (port 6432) — PgBouncer service, used by applications
- `pg-<cluster>-direct` (port 5432) — Direct PostgreSQL access
- `pg-<cluster>-replicas` (port 5432) — Replica access
- Missing endpoints = no healthy pods backing the service

## Step 6: Connection Configuration Review

```bash
kubectl exec -n <NAMESPACE> $MASTER_POD -- env PGPASSWORD="$(kubectl get secret -n <NAMESPACE> postgres-credentials -o jsonpath='{.data.password}' | base64 -d)" psql -U postgres -d postgres -c "
SELECT name, setting, unit FROM pg_settings
WHERE name IN ('max_connections', 'superuser_reserved_connections',
    'idle_in_transaction_session_timeout', 'statement_timeout',
    'tcp_keepalives_idle', 'tcp_keepalives_interval', 'tcp_keepalives_count')
ORDER BY name;
"
```

**Interpret**:
- `idle_in_transaction_session_timeout` = 0 means idle-in-txn connections never timeout (risky)
- TCP keepalives help detect dead connections

Cross-reference Patroni desired config vs actual PostgreSQL settings to detect mismatches:

```bash
echo "=== Patroni config ==="
kubectl exec -n <NAMESPACE> $MASTER_POD -- patronictl -c /patroni/pg_node.yml show-config | grep -E 'tcp_keepalives|idle_in_transaction|statement_timeout'
echo "=== Actual PostgreSQL settings ==="
kubectl exec -n <NAMESPACE> $MASTER_POD -- env PGPASSWORD="$(kubectl get secret -n <NAMESPACE> postgres-credentials -o jsonpath='{.data.password}' | base64 -d)" psql -U postgres -d postgres -c "
SELECT name, setting FROM pg_settings
WHERE name IN ('tcp_keepalives_idle','tcp_keepalives_interval','tcp_keepalives_count',
               'idle_in_transaction_session_timeout','statement_timeout');
"
```

**Interpret**: If Patroni config and actual PostgreSQL settings differ, settings may need a reload (`patronictl reload`) or restart (`patronictl restart`). Some parameters require a full PostgreSQL restart to take effect — check `pending_restart` column in `pg_settings`.

## Summary Report

| Check | Status | Details |
|-------|--------|---------|
| PgBouncer pod | OK/CRITICAL/N/A | Running / Not running / Not installed |
| PgBouncer pools | OK/WARNING | N waiting clients / all served |
| max_connections usage | OK/WARNING/CRITICAL | X% utilization |
| Idle in transaction | OK/WARNING | N connections |
| Connection leaks | OK/WARNING | N leaking applications |
| Service endpoints | OK/CRITICAL | All services have endpoints |
| TCP keepalives | OK/WARNING | Configured / Not configured |
| idle_in_txn timeout | OK/WARNING | Set / Not set (0) |

## Common Issues and Remediation

1. **PgBouncer cl_waiting > 0**: Pool size too small. Increase `default_pool_size` in PgBouncer config.
2. **max_connections near limit**: Applications not closing connections. Enable connection pooling. Check for leaks.
3. **Many idle-in-transaction**: Application bug (not committing/rolling back). Set `idle_in_transaction_session_timeout` to auto-kill.
4. **Service has no endpoints**: No healthy pods. Check pod status with `postgresql-health-check`.
5. **TCP keepalives not set**: Dead connections may linger. Set `tcp_keepalives_idle=60`, `tcp_keepalives_interval=10`, `tcp_keepalives_count=6`.
