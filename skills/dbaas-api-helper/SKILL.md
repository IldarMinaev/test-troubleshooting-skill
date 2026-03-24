---
name: dbaas-api-helper
description: Query DBAAS API for microservice database usage — list databases, check statuses, find physical clusters
---

# DBAAS API Helper

## Purpose

Query the DBAAS aggregator API to answer questions about microservice database usage: which databases exist, what physical clusters they run on, their statuses, and connection details.

## Prerequisites

- `kubectl` with access to the cluster
- `curl` and `jq` available
- DBAAS aggregator deployed and running

Placeholders:
- `<NAMESPACE>`: DBAAS namespace
- `<TARGET_NAMESPACE>`: tenant/application namespace

**Read** [dbaas-architecture.md](../_common/dbaas-architecture.md) using the Read tool before proceeding — it contains API endpoints, component names, and namespace conventions needed to execute the steps below.

> **🔒 SECURITY REQUIRED**: Before executing commands, read [SECURITY.md](../_common/SECURITY.md) for credential handling patterns. Never expose passwords in command output.

## Context: Set Up API Access

```bash
# Port-forward to aggregator
kubectl port-forward -n <NAMESPACE> svc/dbaas-aggregator 8080:8080 &
PF_PID=$!
sleep 2

# Discover the secret name (name is safe to store — values are always retrieved inline)
DBAAS_SECRET=$(kubectl get secrets -n <NAMESPACE> -l app=dbaas-aggregator -o jsonpath='{.items[0].metadata.name}')

# Verify connectivity with inline credential retrieval
curl -s -o /dev/null -w '%{http_code}' \
  -u "$(kubectl get secret -n <NAMESPACE> $DBAAS_SECRET -o jsonpath='{.data.username}' | base64 -d):$(kubectl get secret -n <NAMESPACE> $DBAAS_SECRET -o jsonpath='{.data.password}' | base64 -d)" \
  http://localhost:8080/api/v3/dbaas/physical_databases
```

**Note**: In all queries below, replace `<NAMESPACE>` and `$DBAAS_SECRET` with the actual values from the Context step above. Credentials are always retrieved inline per command.

## Common Queries

### List All Databases in a Namespace

```bash
curl -s \
  -u "$(kubectl get secret -n <NAMESPACE> $DBAAS_SECRET -o jsonpath='{.data.username}' | base64 -d):$(kubectl get secret -n <NAMESPACE> $DBAAS_SECRET -o jsonpath='{.data.password}' | base64 -d)" \
  "http://localhost:8080/api/v3/dbaas/<TARGET_NAMESPACE>/databases/list" | jq .
```

### Get Database Statuses

```bash
curl -s \
  -u "$(kubectl get secret -n <NAMESPACE> $DBAAS_SECRET -o jsonpath='{.data.username}' | base64 -d):$(kubectl get secret -n <NAMESPACE> $DBAAS_SECRET -o jsonpath='{.data.password}' | base64 -d)" \
  "http://localhost:8080/api/v3/dbaas/<TARGET_NAMESPACE>/databases/statuses" | jq .
```

### List Physical Database Clusters

```bash
curl -s \
  -u "$(kubectl get secret -n <NAMESPACE> $DBAAS_SECRET -o jsonpath='{.data.username}' | base64 -d):$(kubectl get secret -n <NAMESPACE> $DBAAS_SECRET -o jsonpath='{.data.password}' | base64 -d)" \
  "http://localhost:8080/api/v3/dbaas/physical_databases" \
  | jq '.[] | {name: .metadata.name, namespace: .metadata.namespace, type: .spec.type}'
```

### Find Which Physical Cluster a Database Uses

```bash
curl -s \
  -u "$(kubectl get secret -n <NAMESPACE> $DBAAS_SECRET -o jsonpath='{.data.username}' | base64 -d):$(kubectl get secret -n <NAMESPACE> $DBAAS_SECRET -o jsonpath='{.data.password}' | base64 -d)" \
  "http://localhost:8080/api/v3/dbaas/<TARGET_NAMESPACE>/databases/list" \
  | jq '.[] | select(.name == "<DB_NAME>") | {name, physicalDatabaseId, connectionProperties}'
```

### Count Databases per Physical Cluster

```bash
curl -s \
  -u "$(kubectl get secret -n <NAMESPACE> $DBAAS_SECRET -o jsonpath='{.data.username}' | base64 -d):$(kubectl get secret -n <NAMESPACE> $DBAAS_SECRET -o jsonpath='{.data.password}' | base64 -d)" \
  "http://localhost:8080/api/v3/dbaas/<TARGET_NAMESPACE>/databases/list" \
  | jq 'group_by(.physicalDatabaseId) | .[] | {cluster: .[0].physicalDatabaseId, count: length}'
```

### Find Databases for a Specific Microservice

```bash
curl -s \
  -u "$(kubectl get secret -n <NAMESPACE> $DBAAS_SECRET -o jsonpath='{.data.username}' | base64 -d):$(kubectl get secret -n <NAMESPACE> $DBAAS_SECRET -o jsonpath='{.data.password}' | base64 -d)" \
  "http://localhost:8080/api/v3/dbaas/<TARGET_NAMESPACE>/databases/list" \
  | jq '.[] | select(.metadata.microserviceName == "<SERVICE_NAME>")'
```

### Check Swagger UI

For discovering additional API endpoints:
```
http://localhost:8080/swagger-ui
```

## Interpreting Results

### Database Status Values

| Status | Meaning |
|--------|---------|
| `ACTIVE` | Database is provisioned and available |
| `CREATING` | Database is being provisioned |
| `DELETING` | Database is being removed |
| `FAILED` | Provisioning or operation failed |
| `UNKNOWN` | Status cannot be determined |

### Connection Properties

Database entries typically include connection properties:
- `host`: Service hostname for connecting
- `port`: PostgreSQL port (usually 5432 or 6432)
- `dbName`: Database name
- `username`: Database user
- `password`: May be a secret reference

## Cleanup

```bash
kill $PF_PID 2>/dev/null
```

## Common Issues and Remediation

1. **Port-forward fails**: Aggregator pod may not be running. Check with `dbaas-check` skill.
2. **401 Unauthorized**: Credentials are wrong. Check the secret contents.
3. **Empty database list**: No databases provisioned in this namespace, or wrong namespace.
4. **Database in FAILED status**: Check aggregator logs for the provisioning error.
5. **Physical cluster not found**: Adapter may not be registered. Check with `dbaas-check` skill.
