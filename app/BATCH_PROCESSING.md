# Batch Processing Architecture

## Overview

The inventory service supports a batch processing mode for running long-running, resource-intensive jobs against the PostgreSQL database. Batch jobs are designed to simulate realistic enterprise workloads such as month-end reporting, parallel data imports, and data migration.

## Architecture

```
┌─────────────────────────────────────────────────────┐
│  Inventory Service (Python)                         │
│  ┌──────────────┐  ┌──────────────┐  ┌───────────┐ │
│  │ Job          │  │  Job         │  │  Mgmt     │ │
│  │ Scheduler    │──│  Executor    │──│  API      │ │
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

## Batch Job Categories

### 1. Reporting Jobs

**Primary job**: `report-generation`

Generates inventory reports using complex SQL aggregations:
- Cross-warehouse inventory summaries
- Stock level analytics with window functions
- Trend analysis over rolling time windows
- Category breakdowns with recursive CTEs

Typical database impact: high CPU, moderate I/O, long-running queries.

### 2. Data Import Jobs

**Primary job**: `parallel-import`

Imports inventory data in parallel across multiple categories:
- Concurrent inserts into partitioned tables
- Bulk COPY operations for large datasets
- Conflict resolution (ON CONFLICT DO UPDATE)
- Connection pool utilization near capacity

Typical database impact: high I/O, high connection utilization, row-level locking.

### 3. Data Management Jobs

**Jobs**: `data-migration`, `data-archival`, `data-export`, `batch-reconciliation`

Long-running data management operations:
- `data-migration`: Schema version upgrades, column transformations
- `data-archival`: Moving aged records to archive tables, storage reclamation
- `data-export`: Snapshot exports to staging tables for downstream consumers
- `batch-reconciliation`: Count verification across warehouses, discrepancy resolution

### 4. Workflow Jobs

**Jobs**: `approval-workflow`, `replication-setup`

Business workflow processing:
- `approval-workflow`: Bulk processing of pending inventory change requests
- `replication-setup`: Configuring cross-region replication slots and subscribers

## Processing Load Levels

Each job runs at a configurable load level:

| Level | Description | Connection Usage | Query Complexity |
|-------|-------------|-----------------|-----------------|
| `low` | Minimal impact | 10-20% of pool | Simple queries |
| `medium` | Moderate load | 40-60% of pool | Standard aggregations |
| `high` | Significant load | 70-85% of pool | Complex joins, window functions |
| `extreme` | Maximum throughput | 90%+ of pool | Cartesian products, large sorts |

## Job Lifecycle

```
1. Startup
   └─ Parse BATCH_JOBS environment variable
   └─ Validate job names against JOB_REGISTRY
   └─ Initialize database connection pool (50 connections)

2. Warmup (optional, controlled by WARMUP_PERIOD)
   └─ Enable jobs one at a time with delays
   └─ Allows gradual ramp-up of database load

3. Execution
   └─ Each job runs in its own thread
   └─ Jobs loop until JOB_DURATION reached or shutdown signal
   └─ Management API accepts runtime enable/disable requests

4. Shutdown
   └─ SIGTERM or SIGINT triggers graceful stop
   └─ Active queries allowed to complete (up to 30s)
   └─ Connection pool drained
   └─ Optional cleanup (GRACEFUL_SHUTDOWN=true)
```

## Management API

When `MANAGEMENT_API_ENABLED=true`, the service exposes an HTTP API on port 8080:

### Endpoints

```
GET  /api/jobs/catalog        List all registered jobs and their descriptions
GET  /api/jobs/active         List currently active jobs with status
POST /api/jobs/enable         Start a job at runtime
POST /api/jobs/disable        Stop a running job
POST /api/emergency-stop      Immediately stop all jobs and exit
GET  /health                  Health check endpoint
```

### Example Usage

```bash
# Get job catalog
curl http://localhost:8080/api/jobs/catalog | jq .

# Check what's running
curl http://localhost:8080/api/jobs/active | jq .

# Start a job
curl -X POST http://localhost:8080/api/jobs/enable \
  -H "Content-Type: application/json" \
  -d '{"job": "data-export", "load": "medium"}'

# Stop a job
curl -X POST http://localhost:8080/api/jobs/disable \
  -H "Content-Type: application/json" \
  -d '{"job": "report-generation"}'

# Emergency stop
curl -X POST http://localhost:8080/api/emergency-stop
```

## Pre-Configured Deployment Scenarios

### Report Generation (`scenarios/report-generation.yaml`)

- Jobs: `report-generation`
- Load: `high`
- Duration: 30 minutes
- Management API: enabled

### Parallel Import (`scenarios/parallel-import.yaml`)

- Jobs: `parallel-import`
- Load: `high`
- Duration: 30 minutes
- Management API: enabled

### Month-End Processing (`scenarios/month-end-processing.yaml`)

- Jobs: `report-generation`, `parallel-import`, `data-migration`
- Load: `medium`
- Duration: 60 minutes
- Warmup: 5 minutes (gradual job start)
- Management API: enabled

## Helm Values Files

| Values File | Mode | Use Case |
|-------------|------|----------|
| `values.yaml` | workload | Default OLTP workload |
| `values-batch-reporting.yaml` | batch | Single report generation job |
| `values-batch-month-end.yaml` | batch | Combined month-end jobs |
| `values-ci.yaml` | batch | Short CI validation run |

## Observability

### Logging

All batch jobs emit structured logs to stdout:

```
2024-02-13 10:15:30 INFO    [report-gen-worker] batch_processor — Starting report generation cycle
2024-02-13 10:15:35 INFO    [report-gen-worker] batch_processor — Generated 15,234 rows in 4.8s
2024-02-13 10:16:00 INFO    [batch_main] batch_main — Active jobs: ['report-generation']
```

### Health Indicators

Monitor these to understand batch job impact:
- `pg_stat_activity` — active queries, wait events, query duration
- `pg_stat_bgwriter` — checkpoint frequency (elevated under high write load)
- PgBouncer pool stats — client wait queue depth
- Table sizes — growth rate during import jobs

## Implementation Files

```
app/
├── batch_main.py          # Batch mode entry point
├── batch_processor.py     # Job scheduler and job implementations
├── management_api.py      # HTTP management API (Flask)
├── main.py                # Workload mode entry point
├── workload.py            # Workload worker implementations
├── config.py              # Environment variable parsing
├── db.py                  # Database connection pool
├── dbaas_client.py        # DBAAS provisioning client
├── launcher.sh            # Mode-selecting entrypoint
├── scenarios/
│   ├── report-generation.yaml     # Report generation deployment
│   ├── parallel-import.yaml       # Parallel import deployment
│   ├── month-end-processing.yaml  # Month-end combined deployment
│   └── manage-deployment.sh       # Deployment helper script
└── helm/
    └── inventory-service/
        ├── Chart.yaml
        ├── values.yaml
        ├── values-batch-reporting.yaml
        ├── values-batch-month-end.yaml
        ├── values-ci.yaml
        └── templates/
            ├── deployment.yaml
            ├── service.yaml
            └── serviceaccount.yaml
```

## References

- [README.md](README.md) — Usage guide and examples
- [QUICK_START.md](QUICK_START.md) — 5-minute start guide
- [helm/inventory-service/values.yaml](helm/inventory-service/values.yaml) — Full Helm configuration reference
