# Troubleshooting Decision Tree

> **Note**: This tree is a quick-reference for mapping symptoms to skills. For systematic investigation with hypothesis tracking, root cause analysis, and structured reporting, use [`common-troubleshooting`](../common-troubleshooting/SKILL.md) instead.

Use this guide to select the right skill based on the symptom or request.

## "The application can't connect to the database"

1. **pgskipper-check** — Is the operator healthy? Are CRDs and CRs in good state?
2. **postgresql-health-check** — Is Patroni running? Are pods up?
3. **postgresql-connection-check** — Is PgBouncer healthy? Are connections exhausted?
4. **monitoring-check** — Are exporters and service endpoints working?

## "The database is slow"

1. **postgresql-performance-check** — Slow queries, lock contention, cache hit ratio
2. **postgresql-connection-check** — Connection saturation, idle-in-transaction
3. **postgresql-storage-check** — Disk full, table bloat, WAL accumulation
4. **postgresql-health-check** — Replication lag affecting read performance

## "Replication is broken / replica is lagging"

1. **postgresql-health-check** — Patroni cluster status, replication lag
2. **postgresql-storage-check** — WAL accumulation from inactive replication slots
3. **postgresql-log-analyzer** — Error patterns in Patroni logs

## "Disk space is running out"

1. **postgresql-storage-check** — PVC usage, database sizes, WAL dir, bloat
2. **postgresql-backup-check** — Backup retention filling disk, WAL archive status
3. **postgresql-performance-check** — Tables needing VACUUM

## "Backups aren't working"

1. **postgresql-backup-check** — Backup daemon, pgBackRest status, schedules
2. **pgskipper-check** — PatroniServices CR status (backup is managed there)

## "The operator is failing / CR stuck in progress"

1. **pgskipper-check** — Full operator health: CRDs, Helm, operator pods, CR status, events

## "I need to check a microservice's database"

1. **dbaas-api-helper** — Query DBAAS API for database info
2. **dbaas-check** — Verify aggregator and adapter health

## "Monitoring is broken / no metrics"

1. **monitoring-check** — Exporter pods, ServiceMonitors, PrometheusRules, dashboards

## "Something is wrong but I don't know what"

1. **pgskipper-check** — Start with operator infrastructure health
2. **postgresql-health-check** — Then check cluster health
3. Follow the decision tree based on findings

## "I want to run a custom SQL query"

1. **postgresql-sql-runner** — Safe SQL execution framework via kubectl exec
