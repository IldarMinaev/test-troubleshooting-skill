---
name: qubership-postgresql-troubleshooting
description: AI-agent skills for troubleshooting PostgreSQL managed by pgskipper-operator in Kubernetes — health, performance, storage, backups, connections, logs, DBAAS, and monitoring
---

# Qubership PostgreSQL Troubleshooting

A collection of AI-agent skills for systematically troubleshooting PostgreSQL databases managed by
[pgskipper-operator](https://github.com/Netcracker/pgskipper-operator) in Kubernetes.
Applications connect via [DBAAS service](https://github.com/Netcracker/qubership-dbaas).

Each skill is an executable markdown prompt that an AI agent reads and follows step-by-step.
No wrapper scripts — the agent IS the execution engine.

## Prerequisites

- `kubectl` configured with cluster access and exec permissions
- `helm` 3.x (for Helm release checks)
- `jq`, `curl`, `rg` (ripgrep), `stern`, `gron`

## Available Skills

Install individual skills from this package:

```bash
apm install <org>/<repo>/skills/<skill-name>
```

| Skill | Description |
|-------|-------------|
| [`common-troubleshooting`](skills/common-troubleshooting/SKILL.md) | Systematic hypothesis-driven troubleshooting — problem definition, investigation, root cause analysis, verified resolution |
| [`pgskipper-check`](skills/pgskipper-check/SKILL.md) | Check pgskipper-operator health — CRDs, Helm releases, CR statuses, operator deployments, logs, and events |
| [`postgresql-health-check`](skills/postgresql-health-check/SKILL.md) | Comprehensive Patroni cluster health — cluster status, replication, pod/node resources, PVC status |
| [`postgresql-performance-check`](skills/postgresql-performance-check/SKILL.md) | Analyze database load — slow queries, bad clients, lock contention, cache efficiency, vacuum health |
| [`postgresql-storage-check`](skills/postgresql-storage-check/SKILL.md) | Check PVC capacity, disk usage inside pods, database/table sizes, WAL accumulation, replication slot bloat, table bloat |
| [`postgresql-backup-check`](skills/postgresql-backup-check/SKILL.md) | Check backup health — backup daemon status, pgBackRest info, backup schedules, WAL archiver, retention |
| [`postgresql-connection-check`](skills/postgresql-connection-check/SKILL.md) | Check PgBouncer (connection-pooler) health, pool stats, max_connections usage, connection leak detection, service endpoints |
| [`postgresql-log-analyzer`](skills/postgresql-log-analyzer/SKILL.md) | Parse Patroni and PostgreSQL container logs for error patterns — FATAL, OOM, disk full, deadlock, operator reconciliation failures |
| [`postgresql-sql-runner`](skills/postgresql-sql-runner/SKILL.md) | Run read-only SQL queries against PostgreSQL via kubectl exec on the Patroni master pod |
| [`dbaas-check`](skills/dbaas-check/SKILL.md) | Check DBAAS aggregator health — adapter registration, ghost/lost databases, API connectivity |
| [`dbaas-api-helper`](skills/dbaas-api-helper/SKILL.md) | Query DBAAS API for microservice database usage — list databases, check statuses, find physical clusters |
| [`monitoring-check`](skills/monitoring-check/SKILL.md) | Validate postgres-exporter, query-exporter, metric-collector status; check ServiceMonitors, PrometheusRules, Grafana dashboards; suggest PromQL |

## Skill Selection Guide

When unsure which skill to use, start with `common-troubleshooting` — it has a built-in decision tree.

| Symptom | Start With |
|---------|-----------|
| Vague or multi-symptom problem | `common-troubleshooting` |
| Operator or cluster not healthy | `pgskipper-check` → `postgresql-health-check` |
| Slow queries / high CPU | `postgresql-performance-check` |
| Disk full / storage growing | `postgresql-storage-check` |
| Connection errors / pool exhaustion | `postgresql-connection-check` |
| Backup failures | `postgresql-backup-check` |
| Error messages in logs | `postgresql-log-analyzer` |
| Application can't get a database | `dbaas-check` → `dbaas-api-helper` |
| Missing metrics / alerts | `monitoring-check` |

## Shared Resources

All skills share:

- [`skills/_common/`](skills/_common/) — Architecture references, security guide, patroni reference, Kubernetes context guide, troubleshooting decision tree
- [`skills/_sql/`](skills/_sql/) — SQL scripts for health checks, performance, replication, connections, storage, locks, and configuration analysis

## Security

All credential handling follows the inline retrieval pattern from [`skills/_common/SECURITY.md`](skills/_common/SECURITY.md).
Passwords are never stored in variables or exposed in command output.
