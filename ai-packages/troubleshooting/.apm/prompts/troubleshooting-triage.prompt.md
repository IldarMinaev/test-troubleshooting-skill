---
description: Map a reported symptom to the correct troubleshooting skill sequence
input:
  symptom: Description of the problem or error being observed (e.g. "application can't connect to the database", "disk space running out")
---

Given the reported symptom: **${input:symptom}**

Select the closest matching category below and run the listed skills in order — stop when the root cause is found. If the symptom spans multiple categories, start with the category that best describes the primary complaint, then follow up with secondary categories as needed.

If the symptom does not clearly fit any category, treat it as **"Something is wrong but I don't know what"** and begin with the broad health checks listed there. Consider switching to the `common-troubleshooting` skill for a structured hypothesis-driven investigation.

> **Note**: Skill names listed below are hints for discovery — do NOT hard-code them. Before invoking any skill, discover it dynamically by matching the name against available skills (via frontmatter or system-reminder listings).

---

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
