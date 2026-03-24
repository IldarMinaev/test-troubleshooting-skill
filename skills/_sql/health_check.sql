-- PostgreSQL Health Check Queries
-- Compatible with PostgreSQL 14-17
-- Usage: kubectl exec -n <ns> <master-pod> -- psql -U postgres -d postgres -f /dev/stdin < health_check.sql

-- ============================================================================
-- Quick Health Overview
-- ============================================================================

SELECT
    'PostgreSQL Health Check' AS check_name,
    now() AS check_time,
    version() AS version,
    pg_is_in_recovery() AS is_replica,
    CASE WHEN pg_is_in_recovery() THEN 'REPLICA' ELSE 'PRIMARY' END AS role,
    pg_postmaster_start_time() AS started_at,
    now() - pg_postmaster_start_time() AS uptime,
    current_database() AS database;

-- ============================================================================
-- Critical Health Indicators
-- ============================================================================

WITH health_checks AS (
    SELECT
        'Database Connections' AS check_name,
        CASE
            WHEN count(*) > (SELECT setting::integer FROM pg_settings WHERE name = 'max_connections') * 0.8 THEN 'CRITICAL'
            WHEN count(*) > (SELECT setting::integer FROM pg_settings WHERE name = 'max_connections') * 0.6 THEN 'WARNING'
            ELSE 'OK'
        END AS status,
        count(*) || ' / ' || (SELECT setting FROM pg_settings WHERE name = 'max_connections') AS details
    FROM pg_stat_activity
    WHERE datname IS NOT NULL

    UNION ALL

    SELECT
        'Replication Lag',
        CASE
            WHEN NOT pg_is_in_recovery() AND EXISTS (SELECT 1 FROM pg_stat_replication) THEN
                CASE
                    WHEN MAX(pg_wal_lsn_diff(sent_lsn, replay_lsn)) > 268435456 THEN 'CRITICAL'
                    WHEN MAX(pg_wal_lsn_diff(sent_lsn, replay_lsn)) > 134217728 THEN 'WARNING'
                    ELSE 'OK'
                END
            WHEN pg_is_in_recovery() THEN 'N/A (replica)'
            ELSE 'NO_REPLICAS'
        END,
        COALESCE(pg_size_pretty(MAX(pg_wal_lsn_diff(sent_lsn, replay_lsn))), 'No replication')
    FROM pg_stat_replication

    UNION ALL

    SELECT
        'Dead Tuples',
        CASE
            WHEN COALESCE(ROUND(SUM(n_dead_tup)::numeric * 100 / NULLIF(SUM(n_live_tup), 0), 2), 0) > 20 THEN 'CRITICAL'
            WHEN COALESCE(ROUND(SUM(n_dead_tup)::numeric * 100 / NULLIF(SUM(n_live_tup), 0), 2), 0) > 10 THEN 'WARNING'
            ELSE 'OK'
        END,
        COALESCE(ROUND(SUM(n_dead_tup)::numeric * 100 / NULLIF(SUM(n_live_tup), 0), 2), 0) || '% dead tuples'
    FROM pg_stat_user_tables

    UNION ALL

    SELECT
        'Long Running Queries',
        CASE
            WHEN count(*) > 5 THEN 'CRITICAL'
            WHEN count(*) > 0 THEN 'WARNING'
            ELSE 'OK'
        END,
        count(*) || ' queries running > 5 min'
    FROM pg_stat_activity
    WHERE state = 'active'
      AND now() - query_start > interval '5 minutes'
      AND pid <> pg_backend_pid()

    UNION ALL

    SELECT
        'Pending Locks',
        CASE
            WHEN count(*) > 10 THEN 'CRITICAL'
            WHEN count(*) > 0 THEN 'WARNING'
            ELSE 'OK'
        END,
        count(*) || ' waiting locks'
    FROM pg_locks
    WHERE NOT granted

    UNION ALL

    SELECT
        'Replication Slots',
        CASE
            WHEN NOT pg_is_in_recovery() AND MAX(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) > 536870912 THEN 'CRITICAL'
            WHEN NOT pg_is_in_recovery() AND MAX(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) > 268435456 THEN 'WARNING'
            ELSE 'OK'
        END,
        COALESCE(pg_size_pretty(MAX(CASE WHEN NOT pg_is_in_recovery() THEN pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) END)), 'No slots or replica')
    FROM pg_replication_slots

    UNION ALL

    SELECT
        'WAL Archive',
        CASE
            WHEN archived_count = 0 AND last_failed_wal IS NOT NULL THEN 'CRITICAL'
            WHEN failed_count > 0 THEN 'WARNING'
            ELSE 'OK'
        END,
        'Archived: ' || archived_count || ', Failed: ' || failed_count
    FROM pg_stat_archiver
)
SELECT * FROM health_checks
ORDER BY
    CASE status
        WHEN 'CRITICAL' THEN 1
        WHEN 'WARNING' THEN 2
        WHEN 'N/A (replica)' THEN 3
        WHEN 'NO_REPLICAS' THEN 4
        ELSE 5
    END,
    check_name;

-- ============================================================================
-- Database Sizes
-- ============================================================================

SELECT
    datname,
    pg_size_pretty(pg_database_size(datname)) AS size,
    (SELECT count(*) FROM pg_stat_activity WHERE datname = d.datname) AS connections,
    datconnlimit AS max_connections
FROM pg_database d
WHERE datallowconn = true
ORDER BY pg_database_size(datname) DESC;

-- ============================================================================
-- Final Health Summary
-- ============================================================================

SELECT
    now() AS check_time,
    version() AS pg_version,
    pg_is_in_recovery() AS is_replica,
    (SELECT count(*) FROM pg_stat_replication) AS replica_count,
    (SELECT count(*) FROM pg_stat_activity WHERE state = 'active' AND pid <> pg_backend_pid()) AS active_queries,
    (SELECT count(*) FROM pg_stat_activity WHERE datname IS NOT NULL) AS total_connections,
    (SELECT setting::integer FROM pg_settings WHERE name = 'max_connections') AS max_connections,
    (SELECT count(*) FROM pg_locks WHERE NOT granted) AS pending_locks,
    (SELECT COALESCE(ROUND(SUM(n_dead_tup)::numeric * 100 / NULLIF(SUM(n_live_tup), 0), 2), 0) FROM pg_stat_user_tables) AS dead_tuple_pct;
