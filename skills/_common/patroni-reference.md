# Patroni Reference

> **🔒 Security Note**: When accessing PostgreSQL with credentials, always follow the patterns in [SECURITY.md](SECURITY.md) to avoid exposing passwords.

## patronictl Commands

All commands require the config file path: `-c /patroni/pg_node.yml`

Execute via kubectl:
```bash
kubectl exec -n <ns> <master-pod> -- patronictl -c /patroni/pg_node.yml <command>
```

| Command | Description |
|---------|-------------|
| `list` | Show cluster members, roles, state, lag |
| `show-config` | Show current Patroni dynamic configuration |
| `history` | Show failover/switchover history |
| `topology` | Show replication topology |
| `version` | Show Patroni version |
| `dsn` | Show connection string for the cluster |

### Output Interpretation for `patronictl list`

| Column | Values | Meaning |
|--------|--------|---------|
| Role | Leader, Replica, Sync Standby | Node's current role |
| State | running, streaming, stopped, start failed | Node's operational state |
| TL | number | Timeline — should match across members |
| Lag in MB | number | Replication lag (replicas only) |

Healthy cluster indicators:
- Exactly one Leader
- All members in `running` or `streaming` state
- Same timeline across all members
- Lag in MB is 0 or near-zero for replicas

## Patroni REST API

Each Patroni pod exposes a REST API on port 8008.

```bash
# From within the cluster
kubectl exec -n <ns> <pod> -- curl -s http://localhost:8008/patroni

# Via port-forward
kubectl port-forward -n <ns> <pod> 8008:8008 &
curl -s http://localhost:8008/patroni
```

| Endpoint | Description |
|----------|-------------|
| `/patroni` | Cluster member info (role, state, timeline, xlog position) |
| `/cluster` | Full cluster status with all members |
| `/config` | Patroni dynamic configuration |
| `/health` | Returns 200 if running, useful for liveness probes |
| `/leader` | Returns 200 only if this node is the leader |
| `/replica` | Returns 200 only if this node is a replica |
| `/read-only` | Returns 200 if safe for read-only queries |
| `/history` | Failover/switchover history |

## Configuration Paths

| Path | Description |
|------|-------------|
| `/patroni/pg_node.yml` | Patroni configuration file |
| `/var/lib/pgsql/data/postgresql_node1/` | PostgreSQL data directory (for node1) (for other nodes, change suffix of the directory) |
| `/var/lib/pgsql/data/postgresql_node1/postgresql.conf` | PostgreSQL config |
| `/var/lib/pgsql/data/postgresql_node1/pg_hba.conf` | Client authentication config |

## PostgreSQL Access from Inside a Pod

```bash
# As postgres user (no password needed inside the pod)
kubectl exec -n <ns> <master-pod> -- psql -U postgres -d postgres -c "SELECT version();"

# With password from secret (inline retrieval - secure)
kubectl exec -n <ns> <master-pod> -- env PGPASSWORD="$(kubectl get secret -n <ns> postgres-credentials -o jsonpath='{.data.password}' | base64 -d)" psql -U postgres -d postgres -c "SELECT 1;"
```

**Note**: The inline pattern above retrieves the password and uses it without exposing it in command output. See [SECURITY.md](SECURITY.md) and [credential-handling.md](credential-handling.md) for detailed patterns.

## Common States and What They Mean

| State | Healthy? | Action |
|-------|----------|--------|
| `running` (Leader) | Yes | Normal operation |
| `streaming` (Replica) | Yes | Normal replication |
| `running` (Replica) | Possibly | Check if replication is active |
| `stopped` | No | Pod/PostgreSQL not running — check logs |
| `start failed` | No | PostgreSQL failed to start — check logs |
| `creating replica` | Transient | Replica is being initialized |
