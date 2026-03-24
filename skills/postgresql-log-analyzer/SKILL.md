---
name: postgresql-log-analyzer
description: Parse Patroni and PostgreSQL container logs for error patterns — FATAL, OOM, disk full, deadlock, operator reconciliation failures
---

# PostgreSQL Log Analyzer

## Purpose

Analyze Patroni and PostgreSQL container logs for error patterns including FATAL errors, OOM kills, disk full conditions, connection refused, deadlocks, and operator reconciliation failures. Correlate events with timeline.

## Prerequisites

- `kubectl` with log access
- Namespace where PostgreSQL is deployed (default: `postgres`)

> **🔒 SECURITY REQUIRED**: Before executing commands, read [SECURITY.md](../_common/SECURITY.md) for credential handling patterns. Never expose passwords in command output.

## Context: Verify Kubernetes Access

```bash
kubectl config current-context
kubectl get pods -n <NAMESPACE> -l app=patroni
```

## Step 1: Recent Patroni/PostgreSQL Errors

Check each Patroni pod for errors:

```bash
# Get all Patroni pods
PATRONI_PODS=$(kubectl get pods -n <NAMESPACE> -l app=patroni -o jsonpath='{.items[*].metadata.name}')

if [ -z "$PATRONI_PODS" ]; then
    echo "ERROR: No Patroni pods found with label app=patroni in namespace <NAMESPACE>"
    echo "Check: kubectl get pods -n <NAMESPACE> | grep -E 'pg-|patroni'"
fi

for POD in $PATRONI_PODS; do
    echo "=== $POD ==="
    kubectl logs -n <NAMESPACE> $POD --tail=2000 | grep -iE 'FATAL|ERROR|PANIC|WARNING|OOM|out of memory|disk full|no space|deadlock|connection refused|could not connect|SIGKILL|killed process' | tail -20
done
```

**Note**: All subsequent steps reuse `$PATRONI_PODS`. If this variable is empty, no loops will execute. Resolve the pod discovery issue before proceeding.

## Step 2: FATAL Errors (PostgreSQL Crashes)

```bash
for POD in $PATRONI_PODS; do
    echo "=== $POD FATAL ==="
    kubectl logs -n <NAMESPACE> $POD --tail=2000 | grep -i 'FATAL' | tail -10
done
```

**Common FATAL patterns**:

| Pattern | Meaning | Action |
|---------|---------|--------|
| `FATAL: password authentication failed` | Wrong credentials | Check secrets |
| `FATAL: too many connections` | max_connections exceeded | Increase limit or fix leaks |
| `FATAL: could not open file` | Disk full or file corruption | Check storage |
| `FATAL: the database system is starting up` | Pod restarting | Check restart reason |
| `FATAL: terminating connection due to administrator command` | Backend was killed | Check who killed it |
| `FATAL: sorry, too many clients already` | Connection limit hit | Check connection pooling |

## Step 3: OOM and Resource Kills

```bash
for POD in $PATRONI_PODS; do
    echo "=== $POD OOM ==="
    kubectl logs -n <NAMESPACE> $POD --previous --tail=100 2>/dev/null | grep -iE 'OOM|out of memory|killed|SIGKILL'
done

# Check pod events for OOMKilled
kubectl get pods -n <NAMESPACE> -l app=patroni -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.containerStatuses[*].lastState.terminated.reason}{"\n"}{end}'
```

**Interpret**: `OOMKilled` in lastState means the container exceeded its memory limit.

**Remediation**: Calculate PostgreSQL memory requirements. Increase memory limits in Helm values, or find memory-hungry queries.

## Step 4: Disk Full Conditions

```bash
for POD in $PATRONI_PODS; do
    echo "=== $POD disk ==="
    kubectl logs -n <NAMESPACE> $POD --tail=2000 | grep -iE 'no space|disk full|could not write|could not extend|WAL.*full' | tail -10
done
```

**Remediation**: See `postgresql-storage-check` for identifying what's consuming disk.

## Step 5: Connection Issues

```bash
for POD in $PATRONI_PODS; do
    echo "=== $POD connections ==="
    kubectl logs -n <NAMESPACE> $POD --tail=2000 | grep -iE 'connection refused|could not connect|too many connections|remaining connection slots' | tail -10
done
```

## Step 6: Deadlock Detection

```bash
for POD in $PATRONI_PODS; do
    echo "=== $POD deadlocks ==="
    kubectl logs -n <NAMESPACE> $POD --tail=2000 | grep -iE 'deadlock detected|deadlock' | tail -10
done
```

**Interpret**: Frequent deadlocks indicate application-level issues (transaction ordering, lock escalation).

## Step 7: Patroni-Specific Events

```bash
for POD in $PATRONI_PODS; do
    echo "=== $POD patroni events ==="
    kubectl logs -n <NAMESPACE> $POD --tail=2000 | grep -iE 'failover|switchover|promote|demote|reinitialize|leader|acquired session lock|lost session lock|starting as a secondary' | tail -10
done
```

**Interpret**: Look for unexpected failovers, repeated leader changes, or reinitializations.

## Step 8: Operator Logs

```bash
# patroni-core-operator
kubectl logs -n <NAMESPACE> -l app.kubernetes.io/name=patroni-core-operator --tail=200 | grep -iE 'error|fail|reconcil|panic' | tail -20

# postgres-operator
kubectl logs -n <NAMESPACE> -l app.kubernetes.io/name=postgres-operator --tail=200 | grep -iE 'error|fail|reconcil|panic' | tail -20
```

**Interpret**:
- Reconciliation errors = operator can't sync desired state
- Repeated errors = underlying issue not self-healing

## Step 9: Kubernetes Events

```bash
kubectl get events -n <NAMESPACE> --sort-by='.lastTimestamp' --field-selector type=Warning | tail -30
```

**Interpret**: Correlate Kubernetes events (scheduling failures, image pulls, probes) with log errors.

## Step 10: Event Timeline Correlation

If a specific incident time is known:

```bash
# Logs around a specific time (adjust --since-time)
for POD in $PATRONI_PODS; do
    echo "=== $POD around incident ==="
    kubectl logs -n <NAMESPACE> $POD --since-time='2025-01-15T10:00:00Z' --tail=200 | head -100
done
```

## Summary Report

| Check | Status | Details |
|-------|--------|---------|
| FATAL errors | OK/WARNING/CRITICAL | N FATAL errors in recent logs |
| OOM kills | OK/CRITICAL | OOMKilled detected / clean |
| Memory Risk | LOW/MEDIUM/HIGH | Based on config vs limits |
| Disk errors | OK/CRITICAL | Disk full errors / clean |
| Connection errors | OK/WARNING | Connection issues / clean |
| Deadlocks | OK/WARNING | N deadlocks detected |
| Patroni events | OK/WARNING | Unexpected failovers / stable |
| Operator errors | OK/WARNING | Reconciliation errors / clean |
| K8s events | OK/WARNING | Warning events / clean |

## Common Issues and Remediation

1. **Repeated FATAL: too many connections**: See `postgresql-connection-check` for connection leak diagnosis.
2. **OOMKilled**: Run `skills/_sql/memory_requirements.sql` to compare PG memory config against pod limits. Run `skills/_sql/memory_intensive_queries.sql` to find queries spilling to disk. See `postgresql-performance-check` for runaway queries. Increase pod memory limits if config exceeds limits.
3. **Disk full errors**: See `postgresql-storage-check` for storage diagnosis and cleanup.
4. **Unexpected failovers**: Check Patroni DCS (etcd/Kubernetes) connectivity. Network partitions can cause split-brain.
5. **Repeated deadlocks**: Application needs transaction ordering fixes. Review conflicting queries.
6. **Operator reconciliation failures**: Check operator pod resources, RBAC permissions, and CRD compatibility.
