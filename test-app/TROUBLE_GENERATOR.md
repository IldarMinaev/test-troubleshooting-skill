# PostgreSQL Trouble Generator

## Overview

This trouble generator creates realistic PostgreSQL issues for testing AI troubleshooting skills and demonstrating AI agent capabilities. It's designed to work with PgSkipper-managed PostgreSQL clusters accessed via DBAAS.

## Architecture

```
┌─────────────────────────────────────────────────────┐
│  Trouble Generator Application (Python)             │
│  ┌──────────────┐  ┌──────────────┐  ┌───────────┐ │
│  │ Trouble      │  │  Workload    │  │  Control  │ │
│  │ Scenarios    │──│  Executor    │──│  API      │ │
│  └──────────────┘  └──────────────┘  └───────────┘ │
└──────────────┬──────────────────────────────────────┘
               │ via DBAAS API
               ▼
┌──────────────────────────────────────────────────────┐
│  DBAAS Aggregator                                    │
│  ┌────────────────────────────────────────────────┐  │
│  │  PostgreSQL Adapter                            │  │
│  └────────────┬───────────────────────────────────┘  │
└───────────────┼──────────────────────────────────────┘
                │
                ▼
┌──────────────────────────────────────────────────────┐
│  PgSkipper Operator                                  │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐          │
│  │ Patroni  │  │ PgBouncer│  │ Backup   │          │
│  │ Cluster  │  │ Pool     │  │ Daemon   │          │
│  └──────────┘  └──────────┘  └──────────┘          │
└──────────────────────────────────────────────────────┘
```

## Trouble Scenario Categories

### 1. Performance Issues

**Detectable by**: `postgresql-performance-check`, `common-troubleshooting`

| Scenario | Description | Implementation | Symptoms |
|----------|-------------|----------------|----------|
| **slow-queries** | Long-running cross-join queries | Generate Cartesian products on large tables | High CPU, pg_stat_activity shows long queries |
| **missing-indexes** | Full table scans on unindexed columns | SELECT with WHERE on unindexed columns | High I/O, slow response times |
| **lock-contention** | Row-level lock competition | Multiple transactions locking same rows | Queries waiting on locks, timeouts |
| **cache-thrashing** | Working set exceeds shared_buffers | Sequential scans on tables larger than cache | Low cache hit ratio, high disk I/O |
| **vacuum-issues** | Prevent autovacuum, create bloat | Long-running transactions, high update rate | Table bloat, slow queries, toast bloat |
| **temp-bloat** | Excessive temporary table usage | Large sorts, hash joins without work_mem | temp_bytes high, disk space usage spikes |

### 2. Connection Issues

**Detectable by**: `postgresql-connection-check`, `postgresql-health-check`

| Scenario | Description | Implementation | Symptoms |
|----------|-------------|----------------|----------|
| **pool-exhaustion** | PgBouncer pool saturation | Open connections > pool size | Connection timeouts, pool queue backlog |
| **idle-in-transaction** | Connections stuck idle | BEGIN; then sleep without COMMIT | High idle_in_transaction count |
| **connection-leaks** | Clients not closing connections | Open connections, never close | max_connections reached, new connections fail |
| **max-connections** | PostgreSQL connection limit hit | Direct connections bypassing pooler | "too many connections" errors |
| **connection-storm** | Rapid connection creation/destruction | Burst of short-lived connections | High connection churn, auth overhead |

### 3. Storage Issues

**Detectable by**: `postgresql-storage-check`, `postgresql-backup-check`

| Scenario | Description | Implementation | Symptoms |
|----------|-------------|----------------|----------|
| **disk-full** | PVC approaching capacity | Rapid INSERT of large rows (1MB each) | Disk space alerts, write failures |
| **wal-accumulation** | WAL files not archived/recycled | Create inactive replication slot | pg_wal directory growing |
| **table-bloat** | Dead tuples not vacuumed | High UPDATE rate + no VACUUM | Table size >> live data, slow scans |
| **index-bloat** | Bloated indexes from updates | Update indexed columns frequently | Index size excessive, slow lookups |
| **replication-slot-bloat** | Inactive slot prevents WAL cleanup | Create slot, don't consume WAL | WAL accumulation, disk space issues |
| **temp-files** | Queries spilling to disk | Sorts/joins exceeding work_mem | Temp file I/O, slow queries |

### 4. Replication Issues

**Detectable by**: `postgresql-health-check`, `postgresql-log-analyzer`

| Scenario | Description | Implementation | Symptoms |
|----------|-------------|----------------|----------|
| **replication-lag** | Replica falls behind master | High write rate on master | Lag seconds increasing, stale reads |
| **broken-slot** | Replication slot corruption | Manual slot manipulation (requires superuser) | Replication stopped, WAL accumulation |
| **cascading-failure** | Replica failure cascades | (Requires pod manipulation) | Multiple replicas down |

### 5. Resource Exhaustion Issues

**Detectable by**: `postgresql-health-check`, `postgresql-log-analyzer`, `monitoring-check`

| Scenario | Description | Implementation | Symptoms |
|----------|-------------|----------------|----------|
| **memory-pressure** | Memory exhaustion, OOM risk | Large temp tables, many connections | High memory usage, potential OOM |
| **cpu-saturation** | CPU-intensive queries | Complex aggregations, regex operations | CPU 100%, query queueing |
| **io-bottleneck** | Disk I/O saturation | Sequential scans on large tables | High iowait, slow queries |

### 6. Application-Level Issues

**Detectable by**: `postgresql-performance-check`, `postgresql-log-analyzer`

| Scenario | Description | Implementation | Symptoms |
|----------|-------------|----------------|----------|
| **deadlocks** | Circular lock dependencies | Cross-update transactions | Deadlock errors in logs |
| **bad-clients** | Clients with problematic patterns | Queries without LIMIT, N+1 patterns | High query count, repeated similar queries |
| **statement-timeout** | Queries exceeding timeout | Long queries with statement_timeout set | Query canceled errors |
| **connection-churn** | High connection/disconnection rate | Rapid connect/query/disconnect cycles | High connection overhead |

### 7. DBAAS-Specific Issues

**Detectable by**: `dbaas-check`, `dbaas-api-helper`

| Scenario | Description | Implementation | Symptoms |
|----------|-------------|----------------|----------|
| **ghost-database** | DB exists but not tracked by DBAAS | Manual DB creation without DBAAS API | Database visible in PostgreSQL, not in DBAAS |
| **orphaned-credentials** | DBAAS tracks DB but it's deleted | Delete DB directly, keep DBAAS record | DBAAS shows active, connection fails |

## Implementation Modes

### Mode 1: Scenario-Based Deployment

Deploy with specific scenarios enabled via Helm values:

```yaml
troubleScenarios:
  enabled:
    - slow-queries
    - pool-exhaustion
    - disk-fill
  intensity: medium  # low, medium, high, extreme
  duration: 3600     # seconds, 0 = infinite
```

### Mode 2: Interactive Control API

HTTP API for runtime control:

```bash
# Enable a trouble scenario
POST /api/troubles/enable
{"scenario": "slow-queries", "intensity": "high"}

# Disable a trouble scenario
POST /api/troubles/disable
{"scenario": "slow-queries"}

# List active troubles
GET /api/troubles/active

# Get scenario catalog
GET /api/troubles/catalog
```

### Mode 3: Schedule-Based Troubles

Generate troubles on a schedule for automated testing:

```yaml
troubleSchedule:
  - scenario: slow-queries
    start: "09:00"
    duration: 1800
    intensity: medium
  - scenario: pool-exhaustion
    start: "10:00"
    duration: 900
    intensity: high
```

## Configuration Parameters

### Global Settings

```python
TROUBLE_MODE = "scenario"  # scenario | api | schedule | chaos
TROUBLE_INTENSITY = "medium"  # low | medium | high | extreme
TROUBLE_DURATION = 3600  # seconds, 0 = run until stopped
TROUBLE_RAMP_UP = 300  # seconds to reach full intensity
CLEANUP_ON_EXIT = true  # restore normal state on shutdown
```

### Scenario-Specific Settings

Each scenario has configurable intensity levels:

```python
SCENARIOS = {
    "slow-queries": {
        "low": {"query_duration_sec": 30, "frequency_sec": 60},
        "medium": {"query_duration_sec": 120, "frequency_sec": 30},
        "high": {"query_duration_sec": 300, "frequency_sec": 10},
        "extreme": {"query_duration_sec": 600, "frequency_sec": 5}
    },
    "pool-exhaustion": {
        "low": {"connections": "50%", "hold_time_sec": 60},
        "medium": {"connections": "80%", "hold_time_sec": 120},
        "high": {"connections": "95%", "hold_time_sec": 300},
        "extreme": {"connections": "100%", "hold_time_sec": 600}
    }
}
```

## Deployment

### Standalone Deployment

```bash
# Build the image
cd test-app
./build.sh trouble-generator:v1.0.0

# Deploy via Helm
helm install trouble-gen ./helm/test-app \
  --set image.tag=v1.0.0 \
  --set mode=trouble \
  --set troubleScenarios.enabled="{slow-queries,pool-exhaustion}" \
  --set troubleScenarios.intensity=medium
```

### Integration with Test App

The existing test-app can switch to trouble mode:

```bash
helm upgrade test-app ./helm/test-app \
  --set mode=trouble \
  --set troubleScenarios.enabled="{slow-queries}"
```

## Testing Workflow

### 1. Single Scenario Testing

Test each AI skill against its primary scenarios:

```bash
# Test postgresql-performance-check skill
kubectl apply -f scenarios/slow-queries.yaml
# Wait for issue to manifest (2-5 minutes)
# Run AI skill: /postgresql-performance-check
# Verify AI correctly identifies slow queries

# Cleanup
kubectl delete -f scenarios/slow-queries.yaml
```

### 2. Multi-Scenario Testing

Test `common-troubleshooting` with compound issues:

```bash
# Deploy multiple scenarios
kubectl apply -f scenarios/compound-issue-1.yaml

# This creates:
# - Slow queries (performance)
# - Pool exhaustion (connections)
# - High disk usage (storage)

# Run AI skill: /common-troubleshooting
# Verify AI performs systematic investigation
# and identifies all root causes
```

### 3. Demo Scenarios

Pre-configured scenarios for demonstrations:

| Demo | Scenarios | Expected Skills | Duration |
|------|-----------|----------------|----------|
| **Performance Degradation** | slow-queries + cache-thrashing | postgresql-performance-check | 5 min |
| **Connection Crisis** | pool-exhaustion + connection-leaks | postgresql-connection-check | 3 min |
| **Storage Emergency** | disk-full + wal-accumulation | postgresql-storage-check | 10 min |
| **Replication Disaster** | replication-lag + broken-slot | postgresql-health-check | 7 min |
| **Mystery Issue** | 3 random scenarios | common-troubleshooting | 15 min |

## Observability

### Metrics Exposed

Prometheus metrics endpoint on `:9090/metrics`:

```
# Active trouble scenarios
trouble_generator_active_scenarios{scenario="slow-queries"} 1

# Trouble intensity level
trouble_generator_intensity{scenario="slow-queries"} 0.8

# Operations performed
trouble_generator_operations_total{scenario="slow-queries",operation="insert"} 1234

# Errors encountered
trouble_generator_errors_total{scenario="slow-queries",error="connection"} 5
```

### Logging

Structured JSON logs with scenario correlation:

```json
{
  "timestamp": "2024-02-13T10:15:30Z",
  "level": "INFO",
  "scenario": "slow-queries",
  "operation": "execute_cross_join",
  "duration_ms": 45200,
  "rows_affected": 1000000
}
```

## Safety Features

### 1. Resource Limits

- **Connection limits**: Never exceed 90% of max_connections
- **Disk usage**: Stop at 85% PVC capacity
- **Memory**: Stay within container limits
- **CPU**: Configurable throttling

### 2. Automatic Cleanup

- On graceful shutdown, restore normal state
- Drop trouble-specific tables/indexes
- Close held connections
- Cancel long-running queries

### 3. Emergency Stop

```bash
# Via API
curl -X POST http://trouble-gen:8080/api/emergency-stop

# Via signal
kubectl exec -n $NS trouble-gen -- kill -USR1 1

# Via Helm
helm upgrade trouble-gen --set enabled=false
```

## Implementation Files

```
test-app/
├── trouble_generator.py      # Main trouble generator logic
├── scenarios/
│   ├── __init__.py
│   ├── performance.py        # Performance issue scenarios
│   ├── connections.py        # Connection issue scenarios
│   ├── storage.py           # Storage issue scenarios
│   ├── replication.py       # Replication issue scenarios
│   └── dbaas.py            # DBAAS-specific scenarios
├── control_api.py           # HTTP API for runtime control
├── scheduler.py             # Schedule-based execution
├── metrics.py              # Prometheus metrics
└── helm/
    └── trouble-generator/
        ├── Chart.yaml
        ├── values.yaml
        └── templates/
            ├── deployment.yaml
            ├── service.yaml
            ├── configmap-scenarios.yaml
            └── rbac.yaml
```

## Usage Examples

### Example 1: Test Performance Skills

```bash
# Deploy trouble generator in scenario mode
helm install perf-test ./helm/trouble-generator \
  --set scenarios.enabled="{slow-queries,missing-indexes}" \
  --set intensity=high \
  --set duration=1800

# Wait for issues to manifest
sleep 300

# Test AI skill
claude-code "Check database performance in namespace test-perf"
# Expected: AI uses postgresql-performance-check
# Identifies slow queries and missing indexes

# Cleanup
helm uninstall perf-test
```

### Example 2: Demo AI Agent Capabilities

```bash
# Deploy compound issue for demo
kubectl apply -f demos/mystery-issue.yaml

# This creates:
# - Slow queries (moderate)
# - Connection pool 80% full
# - Disk at 75% capacity
# - Replication lag 30 seconds

# Demo the AI
claude-code "Something seems wrong with the production database"
# Expected: AI uses common-troubleshooting
# Systematically investigates each area
# Identifies all four issues
# Prioritizes by severity
# Suggests remediation steps

# Cleanup
kubectl delete -f demos/mystery-issue.yaml
```

### Example 3: Automated Regression Testing

```bash
# Run full skill test suite
./test-app/test-skills.sh

# This script:
# 1. Deploys each scenario
# 2. Waits for issue to manifest
# 3. Runs corresponding AI skill
# 4. Validates AI response
# 5. Cleans up
# 6. Reports results

# Output:
# ✓ postgresql-performance-check: PASS (slow-queries detected)
# ✓ postgresql-connection-check: PASS (pool exhaustion detected)
# ✓ postgresql-storage-check: PASS (disk full detected)
# ...
```

## Next Steps

1. **Implement core trouble_generator.py module**
2. **Create scenario implementations** (performance, connections, storage)
3. **Build control API** for runtime management
4. **Package Helm chart** for easy deployment
5. **Create demo scenarios** for presentations
6. **Write test automation scripts** for CI/CD
7. **Document runbooks** for each scenario

## References

- [PgSkipper Architecture](../skills/_common/pgskipper-architecture.md)
- [DBAAS Architecture](../skills/_common/dbaas-architecture.md)
- [Troubleshooting Decision Tree](../skills/_common/troubleshooting-decision-tree.md)
- [Existing Test App](./main.py)
