---
name: postgresql-health-check
description: Comprehensive Patroni cluster health — cluster status, replication, pod/node resources, PVC status
---

# PostgreSQL Health Check

## Purpose

Comprehensive health assessment of a PostgreSQL cluster running under Patroni in Kubernetes. Covers Patroni cluster state, replication, pod resources, PVC status, and key database health indicators.

## Prerequisites

- `kubectl` with exec permissions
- Namespace where PostgreSQL is deployed (default: `postgres`)

**Read** [patroni-reference.md](../_common/patroni-reference.md) using the Read tool before proceeding — it contains configuration paths, data directory locations, and command reference needed to execute the steps below. Also see [kubernetes-context.md](../_common/kubernetes-context.md) and [pgskipper-architecture.md](../_common/pgskipper-architecture.md) for broader context.

> **🔒 SECURITY REQUIRED**: Before executing commands, read [SECURITY.md](../_common/SECURITY.md) for credential handling patterns. Never expose passwords in command output.

## Context: Verify Kubernetes Access

```bash
kubectl config current-context
kubectl get namespace <NAMESPACE>
```

## Step 1: Patroni Cluster Status

```bash
# Find a patroni pod
MASTER_POD=$(kubectl get pods -n <NAMESPACE> -l pgtype=master -o jsonpath='{.items[0].metadata.name}')

# Cluster status
kubectl exec -n <NAMESPACE> $MASTER_POD -- patronictl -c /patroni/pg_node.yml list
```

**Interpret**:
- Exactly one `Leader` — healthy
- All members `running` or `streaming` — healthy
- Same timeline (TL) across all members — healthy
- Lag in MB should be 0 or near-zero for replicas
- `starting` — transient state during pod boot. Should resolve within `primary_start_timeout` (default 30s). Re-check after 30-60 seconds. If it persists, check pod logs for startup errors.
- `stopped` or `start failed` members — CRITICAL

```bash
# Cluster history (failovers/switchovers)
kubectl exec -n <NAMESPACE> $MASTER_POD -- patronictl -c /patroni/pg_node.yml history
```

## Step 2: Pod Health

```bash
# All Patroni pods
kubectl get pods -n <NAMESPACE> -l app=patroni -o wide

# Pod resource usage
kubectl top pods -n <NAMESPACE> -l app=patroni
```

**Interpret**:
- All pods should be `Running` with all containers ready
- Check CPU/memory usage against limits
- Pods on different nodes = good (anti-affinity)
- All pods on the same node = **WARNING** in production — a single node failure will take down the entire cluster. Check if pod anti-affinity rules are configured. May be acceptable in dev/test environments.

```bash
# Check pod events for issues
kubectl describe pods -n <NAMESPACE> -l app=patroni | grep -A5 'Events:'
```

## Step 3: StatefulSet Readiness

```bash
kubectl get statefulsets -n <NAMESPACE> -l app=patroni
```

**Interpret**:
- READY matches REPLICAS (e.g., `2/2`) = healthy
- READY < REPLICAS = **CRITICAL** — pods are failing to start. Check pod events and PVC binding.
- `0/0` replicas = **WARNING** — StatefulSet scaled down, no HA. If only the leader StatefulSet is running, automatic failover is not possible. Verify whether this is intentional (dev/test) or accidental.

## Step 4: Node Resources

```bash
# Nodes hosting PostgreSQL pods
kubectl get pods -n <NAMESPACE> -l app=patroni -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.nodeName}{"\n"}{end}'

# Node resource pressure
kubectl top nodes
```

## Step 5: PVC Status

```bash
kubectl get pvc -n <NAMESPACE>
```

**Interpret**:
- STATUS should be `Bound` for all PVCs
- `Pending` = storage class issue or no available PV
- Review all PVCs, including backup PVCs — not just those labeled `app=patroni`

## Step 6: Postgres logs

Use **postgresql-log-analyzer** skill to check PostgreSQL logs for errors or warnings indicating underlying issues.

## Step 7: Disk Usage Inside Pods

Discover the actual data directory from PostgreSQL, then check disk usage on every Patroni pod:

```bash
DATA_DIR=$(kubectl exec -n <NAMESPACE> $MASTER_POD -- env PGPASSWORD="$(kubectl get secret -n <NAMESPACE> postgres-credentials -o jsonpath='{.data.password}' | base64 -d)" psql -U postgres -d postgres -tAc "SHOW data_directory;")
echo "Data directory: $DATA_DIR"

for POD in $(kubectl get pods -n <NAMESPACE> -l app=patroni -o jsonpath='{.items[*].metadata.name}'); do
    echo "=== $POD ==="
    kubectl exec -n <NAMESPACE> $POD -- df -h "$DATA_DIR"
done
```

WAL and base data breakdown:
```bash
kubectl exec -n <NAMESPACE> $MASTER_POD -- du -sh "$DATA_DIR/pg_wal/" 2>/dev/null
kubectl exec -n <NAMESPACE> $MASTER_POD -- du -sh "$DATA_DIR/base/" 2>/dev/null
```

**Interpret**:
- Usage > 85% = **WARNING**
- Usage > 95% = **CRITICAL** — PostgreSQL will refuse writes when disk is full
- For deeper analysis (WAL bloat, table sizes, inactive slots), run `postgresql-storage-check`

## Step 8: Replication Health (SQL)

Run the replication SQL file — covers streaming replication lag, slots, WAL statistics, archive status, and inactive slot warnings:

```bash
kubectl exec -i -n <NAMESPACE> $MASTER_POD -- env PGPASSWORD="$(kubectl get secret -n <NAMESPACE> postgres-credentials -o jsonpath='{.data.password}' | base64 -d)" psql -U postgres -d postgres -f /dev/stdin < skills/_sql/replication.sql
```

## Step 9: Database Health Indicators (SQL)

Run the health check SQL file — covers connections, replication lag, dead tuples, long-running queries, pending locks, replication slots, WAL archive, database sizes, and an aggregate health summary:

```bash
kubectl exec -i -n <NAMESPACE> $MASTER_POD -- env PGPASSWORD="$(kubectl get secret -n <NAMESPACE> postgres-credentials -o jsonpath='{.data.password}' | base64 -d)" psql -U postgres -d postgres -f /dev/stdin < skills/_sql/health_check.sql
```

**Multi-database note**: `health_check.sql` reports cluster-level and `postgres` database stats. For application databases, also list them and note which need deeper investigation:

```bash
kubectl exec -n <NAMESPACE> $MASTER_POD -- env PGPASSWORD="$(kubectl get secret -n <NAMESPACE> postgres-credentials -o jsonpath='{.data.password}' | base64 -d)" psql -U postgres -d postgres -tAc "
SELECT datname FROM pg_database WHERE datallowconn AND datname NOT IN ('template0','template1','postgres');
"
```

Then rerun `health_check.sql` with `-d <dbname>` for each application database if bloat or dead tuples are suspected.

## Step 10: Service Endpoints

```bash
kubectl get svc -n <NAMESPACE>
kubectl get endpoints -n <NAMESPACE>
```

**Interpret**:
- Services should have endpoints. Missing endpoints = no healthy pods backing the service.
- `pg-patroni-ro` with no endpoints = expected if no replicas are running (see Step 3)
- `postgres-backup-daemon` with no endpoints = **WARNING** — backup pod is not running. Investigate with `postgresql-backup-check`.

## Summary Report

| Check | Status | Details |
|-------|--------|---------|
| Patroni cluster | OK/WARNING/CRITICAL | N members, leader: X, all running |
| Replication lag | OK/WARNING/CRITICAL | Max lag: X MB |
| Pod status | OK/CRITICAL | N/N pods running |
| Pod resources | OK/WARNING | CPU/memory within limits |
| StatefulSets | OK/WARNING/CRITICAL | All ready / Scaled down / Pods failing |
| PVC status | OK/CRITICAL | All bound / Pending found |
| Disk usage | OK/WARNING/CRITICAL | X% used on each pod |
| Connections | OK/WARNING/CRITICAL | X% utilization |
| Dead tuples | OK/WARNING/CRITICAL | X% dead |
| Long queries | OK/WARNING | N queries > 5 min |
| Pending locks | OK/WARNING | N waiting locks |
| Services | OK/CRITICAL | Endpoints present / missing |
| Backup daemon | OK/WARNING | Endpoints present / No pod running |

## Common Issues and Remediation

1. **No leader in Patroni**: Cluster may be in failover. Check patronictl history. Wait for automatic recovery or investigate blocked election.
2. **StatefulSet scaled to 0**: Replica node missing — no HA. Scale up with `kubectl scale statefulset <name> -n <NAMESPACE> --replicas=1`. Verify replica joins and starts streaming.
3. **Deployment scaled to 0**: Operator missing — no maintenance. Supplementary service missing — no functionality of the platform. Scale up with `kubectl scale deployment <name> -n <NAMESPACE> --replicas=1`. Verify created pod logs.
4. **High replication lag**: Check replica pod resources, network between nodes, WAL generation rate vs replay speed.
5. **PVC Pending**: Check StorageClass availability, PV provisioner health, storage quota.
6. **High connection usage**: Check for connection leaks. Consider PgBouncer. See `postgresql-connection-check`.
7. **High dead tuples**: Autovacuum may be lagging. Check `postgresql-performance-check`.
8. **Pod OOMKilled**: Run `skills/_sql/memory_requirements.sql` to check if PG memory config exceeds pod limits. Run `skills/_sql/memory_intensive_queries.sql` to find queries spilling to disk. Increase memory limits in Helm values if needed.
9. **Backup daemon not running**: No endpoints for backup service. Check with `postgresql-backup-check`.
