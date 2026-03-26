# Inventory Service

A PostgreSQL-backed inventory management service that operates in two modes:

1. **Workload Mode**: Continuous OLTP workload (inserts, selects, updates, etc.)
2. **Batch Mode**: Scheduled batch processing jobs (reporting, imports, migrations)

## Quick Start

### Build the Image

```bash
cd app
./build.sh inventory-service:v1.0.0
```

### Deploy in Workload Mode

Generate continuous database workload:

```bash
helm install inventory-service ./helm/inventory-service \
  --set image.tag=v1.0.0 \
  --set dbaas.url="http://dbaas-aggregator:8080" \
  --set dbaas.user="dba_client" \
  --set dbaas.password="your-password"
```

### Deploy in Batch Mode

Run batch processing jobs:

```bash
# Option 1: Using a pre-configured values file
helm install inventory-service ./helm/inventory-service \
  -f helm/inventory-service/values-batch-reporting.yaml \
  --set dbaas.url="http://dbaas-aggregator:8080" \
  --set dbaas.user="dba_client" \
  --set dbaas.password="your-password"

# Option 2: Using the scenario helper script
cd scenarios
NAMESPACE=my-namespace ./manage-deployment.sh deploy report-generation

# Option 3: Direct kubectl apply
kubectl apply -f scenarios/report-generation.yaml -n my-namespace
```

## Available Batch Jobs

| Job | Description | Typical Duration |
|-----|-------------|-----------------|
| `report-generation` | Generates inventory reports with complex aggregations | 30-60 min |
| `parallel-import` | Parallel data import across multiple inventory categories | 15-30 min |
| `data-migration` | Migrates inventory records between schema versions | 30-90 min |
| `data-export` | Exports inventory snapshots to staging tables | 10-20 min |
| `batch-reconciliation` | Reconciles inventory counts across warehouses | 20-40 min |
| `data-archival` | Archives aged inventory records | 60-120 min |
| `approval-workflow` | Processes pending approval requests in bulk | 10-30 min |
| `replication-setup` | Sets up cross-region inventory replication | 5-15 min |

## Usage Examples

### Example 1: Run Report Generation

```bash
# Deploy report generation job
cd scenarios
./manage-deployment.sh deploy report-generation

# Monitor progress
./manage-deployment.sh logs report-generation

# Check status
./manage-deployment.sh status report-generation

# Stop when done
./manage-deployment.sh stop report-generation
```

### Example 2: Run Parallel Import

```bash
./manage-deployment.sh deploy parallel-import

# Wait for import to start
sleep 60

# Monitor via management API
./manage-deployment.sh api parallel-import
# Then: kubectl port-forward svc/inventory-parallel-import 8080:8080
# curl http://localhost:8080/api/jobs/active | jq .

./manage-deployment.sh stop parallel-import
```

### Example 3: Month-End Processing

```bash
# Deploys report-generation + parallel-import + data-migration
./manage-deployment.sh deploy month-end-processing

# Wait for warmup (5 minutes gradual start)
./manage-deployment.sh logs month-end-processing

./manage-deployment.sh stop month-end-processing
```

## Runtime Control via Management API

When `MANAGEMENT_API_ENABLED=true`, you can control jobs at runtime:

```bash
# Port-forward to the management API
kubectl port-forward -n default svc/inventory-report-generation 8080:8080 &

# List available jobs
curl http://localhost:8080/api/jobs/catalog | jq .

# List active jobs
curl http://localhost:8080/api/jobs/active | jq .

# Enable a job at runtime
curl -X POST http://localhost:8080/api/jobs/enable \
  -H "Content-Type: application/json" \
  -d '{"job": "data-export", "load": "medium"}' | jq .

# Disable a job
curl -X POST http://localhost:8080/api/jobs/disable \
  -H "Content-Type: application/json" \
  -d '{"job": "report-generation"}' | jq .

# Emergency stop all jobs
curl -X POST http://localhost:8080/api/emergency-stop | jq .
```

## Configuration

### Environment Variables (Batch Mode)

| Variable | Description | Default | Required |
|----------|-------------|---------|----------|
| `DBAAS_URL` | DBAAS aggregator URL | - | Yes |
| `DBAAS_USER` | DBAAS username | - | Yes |
| `DBAAS_PASSWORD` | DBAAS password | - | Yes |
| `APP_NAMESPACE` | Kubernetes namespace | - | Yes |
| `MODE` | Application mode (`workload` or `batch`) | `workload` | No |
| `BATCH_JOBS` | Comma-separated list of jobs to run | - | Yes (batch mode) |
| `PROCESSING_LOAD` | Load level: `low`, `medium`, `high`, `extreme` | `medium` | No |
| `JOB_DURATION` | Duration in seconds (0=infinite) | `0` | No |
| `WARMUP_PERIOD` | Ramp-up time in seconds | `0` | No |
| `GRACEFUL_SHUTDOWN` | Clean shutdown on exit | `true` | No |
| `MANAGEMENT_API_ENABLED` | Enable HTTP management API | `false` | No |

### Load Levels

Each batch job supports four processing load levels:

- **low**: Minimal database impact, suitable for CI validation
- **medium**: Moderate load, suitable for staging environments
- **high**: Significant load, representative of production workloads
- **extreme**: Maximum throughput, stress testing only

## Helper Scripts

### scenarios/manage-deployment.sh

Manages scenario deployments:

```bash
# List available scenarios
./manage-deployment.sh list

# Deploy a scenario
./manage-deployment.sh deploy report-generation

# Check deployment status
./manage-deployment.sh status report-generation

# View logs
./manage-deployment.sh logs report-generation

# Get management API info
./manage-deployment.sh api report-generation

# Stop a scenario
./manage-deployment.sh stop report-generation

# Stop all running scenarios
./manage-deployment.sh stop-all

# Full run (deploy + wait for ready)
./manage-deployment.sh run report-generation
```

## Architecture

```
┌─────────────────────────────────────────┐
│  Inventory Service Container             │
│  ┌────────────┐    ┌─────────────────┐  │
│  │ launcher.sh│───▶│   main.py       │  │
│  │            │    │ (workload mode) │  │
│  └────────────┘    └─────────────────┘  │
│       │                                  │
│       └──────────▶┌─────────────────┐   │
│                   │  batch_main.py  │   │
│                   │  (batch mode)   │   │
│                   └────────┬────────┘   │
│                            │             │
│                   ┌────────▼────────┐   │
│                   │  JobScheduler   │   │
│                   └────────┬────────┘   │
│                            │             │
│              ┌─────────────┼────────┐   │
│              ▼             ▼        ▼   │
│         ReportGen    ParallelImport  …  │
│         Job          Job                │
│                                          │
└──────────────┬───────────────────────────┘
               │ via DBAAS
               ▼
       ┌──────────────────┐
       │ PostgreSQL       │
       │ (PgSkipper)      │
       └──────────────────┘
```

## Development

### Adding New Batch Jobs

1. Create a job class in `batch_processor.py`:

```python
class MyNewJob(BatchJob):
    def __init__(self):
        super().__init__(
            name="my-job",
            description="What this job does"
        )

    def _run(self, load: LoadLevel, shutdown_event: threading.Event):
        # Implementation
        pass

    def cleanup(self):
        # Cleanup logic
        pass
```

2. Register in `JOB_REGISTRY`:

```python
JOB_REGISTRY = {
    # ...
    "my-job": MyNewJob,
}
```

3. Create deployment YAML in `scenarios/my-job.yaml`

4. Test it:

```bash
./scenarios/manage-deployment.sh deploy my-job
```

### Testing Locally

Run in Docker without Kubernetes:

```bash
# Build image
docker build -t inventory-service:test .

# Run in batch mode
docker run --rm \
  -e MODE=batch \
  -e DBAAS_URL=http://dbaas:8080 \
  -e DBAAS_USER=dba_client \
  -e DBAAS_PASSWORD=password \
  -e APP_NAMESPACE=test \
  -e BATCH_JOBS=report-generation \
  -e PROCESSING_LOAD=low \
  -e JOB_DURATION=300 \
  inventory-service:test
```

## Troubleshooting

### Pod Not Starting

Check logs:
```bash
kubectl logs -l app=inventory-service -n <namespace>
```

Common causes:
- DBAAS credentials incorrect
- Database provisioning failed
- Insufficient CPU/memory resources
- Network connectivity to DBAAS

### Jobs Not Running

- Verify `BATCH_JOBS` environment variable is set correctly
- Check job names match entries in `JOB_REGISTRY`
- Review pod logs for startup errors
- Ensure database schema initialized successfully

### Management API Not Responding

- Verify `MANAGEMENT_API_ENABLED=true`
- Port-forward to the correct service
- Check pod logs for Flask startup errors

## See Also

- [BATCH_PROCESSING.md](BATCH_PROCESSING.md) - Batch processing architecture details
- [helm/inventory-service/values.yaml](helm/inventory-service/values.yaml) - Full Helm configuration reference
