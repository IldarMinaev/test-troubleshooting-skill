# Inventory Service — Quick Start

## 5-Minute Start

```bash
# 1. Build
cd app && ./build.sh inventory-service:latest

# 2. Deploy a batch scenario
cd scenarios
NAMESPACE=test ./manage-deployment.sh deploy report-generation

# 3. Monitor the job
./manage-deployment.sh logs report-generation

# 4. Stop when done
./manage-deployment.sh stop report-generation
```

## Available Scenarios

| Scenario | Jobs | Load | Duration |
|----------|------|------|----------|
| `report-generation` | report-generation | high | 30 min |
| `parallel-import` | parallel-import | high | 30 min |
| `month-end-processing` | report-generation, parallel-import, data-migration | medium | 60 min |

## Common Commands

```bash
# List scenarios
./manage-deployment.sh list

# Deploy
./manage-deployment.sh deploy <scenario>

# Check status
./manage-deployment.sh status <scenario>

# View logs
./manage-deployment.sh logs <scenario>

# Stop
./manage-deployment.sh stop <scenario>

# Stop all
./manage-deployment.sh stop-all
```

## Helm Deployment

```bash
# Workload mode (continuous OLTP)
helm install inventory-service ./helm/inventory-service \
  --set dbaas.url="http://dbaas-aggregator:8080" \
  --set dbaas.user="dba_client" \
  --set dbaas.password="your-password"

# Batch reporting (pre-configured values file)
helm install inventory-service ./helm/inventory-service \
  -f helm/inventory-service/values-batch-reporting.yaml \
  --set dbaas.url="http://dbaas-aggregator:8080" \
  --set dbaas.user="dba_client" \
  --set dbaas.password="your-password"

# Month-end processing
helm install inventory-service ./helm/inventory-service \
  -f helm/inventory-service/values-batch-month-end.yaml \
  --set dbaas.url="http://dbaas-aggregator:8080" \
  --set dbaas.user="dba_client" \
  --set dbaas.password="your-password"

# CI validation
helm install inventory-service ./helm/inventory-service \
  -f helm/inventory-service/values-ci.yaml \
  --set dbaas.existingSecret="ci-dbaas-credentials"
```

## Management API

```bash
# Port-forward
kubectl port-forward svc/inventory-report-generation 8080:8080 &

# List active jobs
curl http://localhost:8080/api/jobs/active | jq .

# Enable a job at runtime
curl -X POST http://localhost:8080/api/jobs/enable \
  -H "Content-Type: application/json" \
  -d '{"job":"data-export","load":"medium"}'

# Emergency stop
curl -X POST http://localhost:8080/api/emergency-stop
```

## Key Configuration

Set via environment variables or ConfigMap:

```yaml
MODE: batch                          # Enable batch mode
BATCH_JOBS: report-generation        # Or comma-separated list
PROCESSING_LOAD: medium              # low|medium|high|extreme
JOB_DURATION: 1800                   # Seconds (0=infinite)
MANAGEMENT_API_ENABLED: true         # Enable HTTP API
```

## Troubleshooting

### Pod not starting?
```bash
# Check logs
kubectl logs -l app=inventory-service -n <namespace>

# Common fixes:
# - Verify DBAAS credentials
# - Check resource limits
# - Ensure namespace exists
```

### Jobs not running?
```bash
# Check BATCH_JOBS env var is set
kubectl get pod <pod-name> -o jsonpath='{.spec.containers[0].env}' | jq .

# Check available jobs in logs
kubectl logs <pod-name> | grep "Available jobs"
```

### Emergency cleanup?
```bash
# Stop all scenarios
./manage-deployment.sh stop-all

# Delete stuck resources
kubectl delete pods,deployments,services,configmaps \
  -l app=inventory-service -n <namespace>
```

## Documentation

- **README.md** — Full usage guide
- **BATCH_PROCESSING.md** — Batch processing architecture
- **helm/inventory-service/values.yaml** — Helm configuration reference
