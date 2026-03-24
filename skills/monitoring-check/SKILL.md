---
name: monitoring-check
description: Validate postgres-exporter, query-exporter, metric-collector status; check ServiceMonitors, PrometheusRules, Grafana dashboards; suggest PromQL
---

# Monitoring Check

## Purpose

Validate the PostgreSQL monitoring stack: exporter pod health, ServiceMonitor/PrometheusRule resources, Grafana dashboard ConfigMaps, and provide PromQL queries for VictoriaMetrics/Prometheus.

## Prerequisites

- `kubectl` with access to the target cluster
- Namespace where PostgreSQL is deployed (default: `postgres`)
- `patroni-services` Helm release installed with monitoring enabled

See [pgskipper-architecture.md](../_common/pgskipper-architecture.md) for broader context on component names and namespace conventions.

> **🔒 SECURITY REQUIRED**: Before executing commands, read [SECURITY.md](../_common/SECURITY.md) for credential handling patterns. Never expose passwords in command output.

## Context: Verify Kubernetes Access

```bash
kubectl config current-context
kubectl get namespace <NAMESPACE>
```

## Step 1: Check Exporter Pods

```bash
# postgres-exporter — PostgreSQL metrics for Prometheus
kubectl get pods -n <NAMESPACE> -l app=postgres-exporter -o wide

# query-exporter — Custom SQL query metrics
kubectl get pods -n <NAMESPACE> -l app=query-exporter -o wide

# metric-collector — Aggregated metrics
kubectl get pods -n <NAMESPACE> -l app=metric-collector -o wide
```

**Interpret**: All exporter pods should be `Running` with all containers ready.

For any not-running pod:
```bash
kubectl describe pod -n <NAMESPACE> <pod-name>
kubectl logs -n <NAMESPACE> <pod-name> --tail=50
```

## Step 2: Check Exporter Services and Endpoints

```bash
# Services
kubectl get svc -n <NAMESPACE> | grep -E 'exporter|metric-collector'

# Endpoints (must have IPs for Prometheus to scrape)
kubectl get endpoints -n <NAMESPACE> | grep -E 'exporter|metric-collector'
```

**Interpret**: Each exporter service must have endpoints. No endpoints = Prometheus cannot scrape metrics.

## Step 3: Verify Metrics Are Being Served

First, discover the actual metrics ports from the service definitions:

```bash
kubectl get svc -n <NAMESPACE> -l app=postgres-exporter -o jsonpath='{.items[0].spec.ports[0].targetPort}'
kubectl get svc -n <NAMESPACE> -l app=query-exporter -o jsonpath='{.items[0].spec.ports[0].targetPort}'
```

Default ports are `9187` (postgres-exporter) and `9560` (query-exporter), but they may differ per deployment. Use the discovered ports.

```bash
# Test postgres-exporter metrics endpoint
EXPORTER_POD=$(kubectl get pods -n <NAMESPACE> -l app=postgres-exporter -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -n "$EXPORTER_POD" ]; then
    kubectl exec -n <NAMESPACE> $EXPORTER_POD -- curl -s http://localhost:9187/metrics | head -20
fi

# Test query-exporter metrics endpoint
QE_POD=$(kubectl get pods -n <NAMESPACE> -l app=query-exporter -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -n "$QE_POD" ]; then
    kubectl exec -n <NAMESPACE> $QE_POD -- curl -s http://localhost:9560/metrics | head -20
fi
```

**Interpret**: Should return Prometheus-format metrics (lines starting with `# HELP`, `# TYPE`, or metric names). If curl fails or returns empty output, the exporter may be crashing or misconfigured — check logs in Step 8.

## Step 4: Check ServiceMonitor Resources

```bash
kubectl get servicemonitors -n <NAMESPACE> | grep -iE 'postgres|patroni|exporter'
```

If found, check details:
```bash
kubectl get servicemonitors -n <NAMESPACE> -o yaml | grep -A10 'selector:'
```

**Interpret**: ServiceMonitors tell Prometheus what to scrape. If missing, metrics won't be collected even if exporters are running.

## Step 5: Check PrometheusRule Resources

```bash
kubectl get prometheusrules -n <NAMESPACE> | grep -iE 'postgres|patroni'
```

If found:
```bash
kubectl get prometheusrules -n <NAMESPACE> -o yaml | grep -E 'alert:|expr:'
```

**Interpret**: PrometheusRules define alerting rules. Missing rules = no alerts even when things go wrong.

## Step 6: Check Grafana Dashboard ConfigMaps

```bash
kubectl get configmaps -n <NAMESPACE> -l grafana_dashboard=1
kubectl get configmaps -n <NAMESPACE> | grep -iE 'dashboard|grafana'
```

**Interpret**: Grafana dashboards are typically stored as ConfigMaps with the `grafana_dashboard=1` label. Missing = no pre-configured dashboards.

## Step 7: Check Exporter Configuration

```bash
# postgres-exporter config
kubectl get configmap -n <NAMESPACE> -l app=postgres-exporter -o yaml 2>/dev/null | grep -A5 'queries.yaml'

# query-exporter config
kubectl get configmap -n <NAMESPACE> -l app=query-exporter -o yaml 2>/dev/null | grep -A5 'config.yaml'
```

## Step 8: Exporter Logs for Errors

```bash
# postgres-exporter
kubectl logs -n <NAMESPACE> -l app=postgres-exporter --tail=30 | grep -iE 'error|fail|cannot|refused'

# query-exporter
kubectl logs -n <NAMESPACE> -l app=query-exporter --tail=30 | grep -iE 'error|fail|cannot|refused'

# metric-collector
kubectl logs -n <NAMESPACE> -l app=metric-collector --tail=30 | grep -iE 'error|fail|cannot|refused'
```

## Useful PromQL Queries

Suggest these to the user for monitoring in VictoriaMetrics/Prometheus:

### Database Health
```promql
# PostgreSQL up
pg_up

# Replication lag in bytes
pg_replication_lag_bytes

# Number of active connections
pg_stat_activity_count{state="active"}

# Connection utilization percentage
pg_stat_activity_count / pg_settings_max_connections * 100

# Dead tuples ratio
pg_stat_user_tables_n_dead_tup / (pg_stat_user_tables_n_live_tup + pg_stat_user_tables_n_dead_tup) * 100
```

### Performance
```promql
# Cache hit ratio
pg_stat_database_blks_hit / (pg_stat_database_blks_hit + pg_stat_database_blks_read) * 100

# Transaction rate
rate(pg_stat_database_xact_commit[5m])

# Rollback rate
rate(pg_stat_database_xact_rollback[5m])

# Rows inserted per second
rate(pg_stat_database_tup_inserted[5m])
```

### Alerts
```promql
# High connection usage (>80%)
pg_stat_activity_count / pg_settings_max_connections > 0.8

# Replication lag > 100MB
pg_replication_lag_bytes > 104857600

# PostgreSQL down
pg_up == 0

# High dead tuple ratio (>10%)
pg_stat_user_tables_n_dead_tup / (pg_stat_user_tables_n_live_tup + 1) > 0.1
```

## Summary Report

| Check | Status | Details |
|-------|--------|---------|
| postgres-exporter | OK/CRITICAL/N/A | Running / Not running / Not installed |
| query-exporter | OK/CRITICAL/N/A | Running / Not running / Not installed |
| metric-collector | OK/CRITICAL/N/A | Running / Not running / Not installed |
| Exporter services | OK/CRITICAL | Endpoints present / missing |
| Metrics serving | OK/CRITICAL | Returning metrics / errors |
| ServiceMonitors | OK/WARNING | Present / Missing |
| PrometheusRules | OK/WARNING | Present / Missing |
| Grafana dashboards | OK/WARNING | Present / Missing |
| Exporter logs | OK/WARNING | Clean / Errors found |

## Common Issues and Remediation

1. **Exporter not installed**: Enable in `patroni-services` Helm values (`metricCollector.install=true`).
2. **Exporter can't connect to PostgreSQL**: Check credentials in exporter config/secret. Verify PostgreSQL is accepting connections.
3. **ServiceMonitor missing**: Create one matching the exporter service labels. Or reinstall `patroni-services` with monitoring enabled.
4. **Prometheus not scraping**: Check Prometheus targets page. Verify ServiceMonitor label selectors match Prometheus operator configuration.
5. **No Grafana dashboards**: Create ConfigMap with `grafana_dashboard=1` label containing the dashboard JSON.
6. **Exporter returning errors**: Check exporter logs for connection issues, query timeouts, or permission errors.
