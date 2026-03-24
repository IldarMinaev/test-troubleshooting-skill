# pgskipper-operator Architecture Reference

## Custom Resource Definitions (CRDs)

| CRD | Purpose |
|-----|---------|
| `patronicores.netcracker.com` | Manages Patroni PostgreSQL cluster (StatefulSets, Services, PVCs) |
| `patroniservices.netcracker.com` | Manages supplementary services (backup, monitoring, connection pooler) |

### CR Status Conditions

Status values for both CRs: `In progress`, `Failed`, `Successful`

```bash
# Check CR status
kubectl get patronicores -n <ns> -o jsonpath='{.items[*].status}'
kubectl get patroniservices -n <ns> -o jsonpath='{.items[*].status}'
```

## Operator Deployments

| Deployment | Purpose |
|-----------|---------|
| `patroni-core-operator` | Reconciles PatroniCore CRs |
| `postgres-operator` | Reconciles PatroniServices CRs |

## Helm Charts

| Chart | Manages |
|-------|---------|
| `patroni-core` | PostgreSQL cluster + core operator |
| `patroni-services` | Supplementary services (backup, monitoring, pooler) |

```bash
helm list -n <ns> --filter 'patroni'
```

## StatefulSets

Pattern: `pg-<clusterName>-node<N>` (older) or StatefulSet named after the cluster.

Labels:
- `app=patroni` — all Patroni pods
- `pgtype=master` — current primary pod
- `pgtype=replica` — replica pods

```bash
kubectl get statefulsets -n <ns> -l app=patroni
kubectl get pods -n <ns> -l app=patroni
kubectl get pods -n <ns> -l pgtype=master
```

## Services

| Service | Port | Purpose |
|---------|------|---------|
| `pg-<cluster>` | 6432 | Client access via PgBouncer |
| `pg-<cluster>-direct` | 5432 | Direct PostgreSQL access (bypasses pooler) |
| `pg-<cluster>-replicas` | 5432 | Read replica access |

## PgBouncer (Connection Pooler)

- Deployment: `connection-pooler`
- Port: 6432
- Fronts the PostgreSQL service for client connections

## Backup

- Deployment: `postgres-backup-daemon` (REST API on port 8080)
- Sidecar: `pgbackrest-sidecar` container in Patroni pods
- Tool: pgBackRest

## Monitoring

| Component | Purpose |
|-----------|---------|
| `postgres-exporter` | PostgreSQL metrics for Prometheus |
| `query-exporter` | Custom SQL query metrics |
| `metric-collector` | Aggregated metric collection |

## Secrets

| Secret | Contents |
|--------|----------|
| `postgres-credentials` | `password` key with superuser password |
| `replicator-credentials` | Replication user password |

## Patroni Configuration

- Config file inside pods: `/patroni/pg_node.yml`
- REST API: port 8008 on each Patroni pod
- Patroni scope/cluster name is in the config

## Key Commands

```bash
# Patroni cluster status
kubectl exec -n <ns> <master-pod> -- patronictl -c /patroni/pg_node.yml list

# Patroni cluster configuration
kubectl exec -n <ns> <master-pod> -- patronictl -c /patroni/pg_node.yml show-config

# Patroni member history
kubectl exec -n <ns> <master-pod> -- patronictl -c /patroni/pg_node.yml history
```
