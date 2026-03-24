---
name: dbaas-check
description: Check DBAAS aggregator health — adapter registration, ghost/lost databases, API connectivity
---

# DBAAS Health Check

## Purpose

Diagnose the health of the DBAAS (Database as a Service) layer: aggregator pod status, adapter registration, database tracking consistency (ghost/lost databases), and API connectivity.

## Prerequisites

- `kubectl` with access to the target cluster
- Namespace where DBAAS is deployed
- DBAAS credentials (see [credential-handling.md](../_common/credential-handling.md))

Placeholders:
- `<NAMESPACE>`: DBAAS namespace
- `<PG_NAMESPACE>`: PostgreSQL namespace if different

**Read** [dbaas-architecture.md](../_common/dbaas-architecture.md) using the Read tool before proceeding — it contains API endpoints, component names, and namespace conventions needed to execute the steps below.

> **🔒 SECURITY REQUIRED**: Before executing commands, read [SECURITY.md](../_common/SECURITY.md) for credential handling patterns. Never expose passwords in command output.

## Context: Verify Kubernetes Access

```bash
kubectl config current-context
kubectl get namespace <NAMESPACE>
```

## Step 1: Check Aggregator Pod

```bash
kubectl get pods -n <NAMESPACE> -l app=dbaas-aggregator -o wide
kubectl get deployment -n <NAMESPACE> dbaas-aggregator
```

**Interpret**: Pod must be `Running` with all containers ready. Deployment should show desired = available replicas.

If not running:
```bash
kubectl describe pod -n <NAMESPACE> -l app=dbaas-aggregator
kubectl logs -n <NAMESPACE> -l app=dbaas-aggregator --tail=50
```

## Step 2: Check Aggregator Service

```bash
kubectl get svc -n <NAMESPACE> dbaas-aggregator
kubectl get endpoints -n <NAMESPACE> dbaas-aggregator
```

**Interpret**: Service should have endpoints. No endpoints = aggregator pod is not healthy.

## Step 3: Port-Forward and Test API

```bash
kubectl port-forward -n <NAMESPACE> svc/dbaas-aggregator 8080:8080 &
PF_PID=$!
sleep 2
```

Discover the secret name and test connectivity (credentials retrieved inline — never stored in variables):
```bash
# Find the secret name (the name is safe to store; only the value must stay inline)
DBAAS_SECRET=$(kubectl get secrets -n <NAMESPACE> -l app=dbaas-aggregator -o jsonpath='{.items[0].metadata.name}')

# Test connectivity with inline credential retrieval
curl -s -o /dev/null -w '%{http_code}' \
  -u "$(kubectl get secret -n <NAMESPACE> $DBAAS_SECRET -o jsonpath='{.data.username}' | base64 -d):$(kubectl get secret -n <NAMESPACE> $DBAAS_SECRET -o jsonpath='{.data.password}' | base64 -d)" \
  http://localhost:8080/api/v3/dbaas/physical_databases
```

**Interpret**: HTTP 200 = healthy. 401 = auth issue. 5xx = aggregator error.

## Step 4: Check Adapter Registration

```bash
curl -s -u "$(kubectl get secret -n <NAMESPACE> $DBAAS_SECRET -o jsonpath='{.data.username}' | base64 -d):$(kubectl get secret -n <NAMESPACE> $DBAAS_SECRET -o jsonpath='{.data.password}' | base64 -d)" http://localhost:8080/api/v3/dbaas/physical_databases | jq '.[].metadata.name'
```

**Interpret**: Each physical PostgreSQL cluster should appear. Missing clusters = adapter not registered or adapter pod is down.

Check adapter pods:
```bash
kubectl get pods -n <NAMESPACE> | grep -i adapter
```

## Step 5: Check Database Statuses

```bash
curl -s -u "$(kubectl get secret -n <NAMESPACE> $DBAAS_SECRET -o jsonpath='{.data.username}' | base64 -d):$(kubectl get secret -n <NAMESPACE> $DBAAS_SECRET -o jsonpath='{.data.password}' | base64 -d)" http://localhost:8080/api/v3/dbaas/<NAMESPACE>/databases/statuses | jq .
```

**Interpret**: All databases should have a healthy status. Failed statuses indicate provisioning or connectivity issues.

## Step 6: Detect Ghost and Lost Databases

**Ghost databases** — exist in PostgreSQL but not tracked by DBAAS. If the PostgreSQL cluster runs in a different namespace, set `PG_NAMESPACE` accordingly (often `postgres`).

```bash
# List databases known to DBAAS
DBAAS_DBS=$(curl -s -u "$(kubectl get secret -n <NAMESPACE> $DBAAS_SECRET -o jsonpath='{.data.username}' | base64 -d):$(kubectl get secret -n <NAMESPACE> $DBAAS_SECRET -o jsonpath='{.data.password}' | base64 -d)" http://localhost:8080/api/v3/dbaas/<NAMESPACE>/databases/list | jq -r '.[].name')

# List databases in PostgreSQL (may be a different namespace)
PG_NAMESPACE=<PG_NAMESPACE>
MASTER_POD=$(kubectl get pods -n $PG_NAMESPACE -l pgtype=master -o jsonpath='{.items[0].metadata.name}')
PG_DBS=$(kubectl exec -n $PG_NAMESPACE $MASTER_POD -- env PGPASSWORD="$(kubectl get secret -n $PG_NAMESPACE postgres-credentials -o jsonpath='{.data.password}' | base64 -d)" psql -U postgres -d postgres -t -c "SELECT datname FROM pg_database WHERE datallowconn AND datname NOT IN ('postgres', 'template0', 'template1');")

# Compare
echo "Ghost databases (in PG but not in DBAAS):"
comm -23 <(echo "$PG_DBS" | sort) <(echo "$DBAAS_DBS" | sort)

echo "Lost databases (in DBAAS but not in PG):"
comm -13 <(echo "$PG_DBS" | sort) <(echo "$DBAAS_DBS" | sort)
```

**Interpret**:
- Ghost databases may be manually created or left over from failed cleanup
- Lost databases indicate DBAAS tracking data is stale or databases were dropped outside DBAAS

## Step 7: Check Aggregator Logs

```bash
kubectl logs -n <NAMESPACE> -l app=dbaas-aggregator --tail=50 | grep -iE 'error|warn|fail'
```

## Cleanup

```bash
# Kill port-forward
kill $PF_PID 2>/dev/null
```

## Summary Report

| Check | Status | Details |
|-------|--------|---------|
| Aggregator pod | OK/CRITICAL | Running / Not running |
| Aggregator service | OK/CRITICAL | Endpoints present / missing |
| API connectivity | OK/CRITICAL | HTTP 200 / error code |
| Adapter registration | OK/WARNING | N clusters registered / missing |
| Database statuses | OK/WARNING | All healthy / N failed |
| Ghost databases | OK/WARNING | N ghost databases found |
| Lost databases | OK/WARNING | N lost databases found |
| Aggregator logs | OK/WARNING | Clean / errors found |

## Common Issues and Remediation

1. **Aggregator not running**: Check pod events and logs. May be image pull failure, OOM, or config error.
2. **No adapters registered**: Check adapter pods. Adapter may be unable to reach aggregator.
3. **Ghost databases**: Manually created DBs or failed DBAAS cleanup. Document and decide if cleanup needed.
4. **Lost databases**: DBAAS metadata out of sync. May need aggregator resync or manual cleanup.
5. **Auth failure (401)**: Verify credentials in the secret match what aggregator expects.
