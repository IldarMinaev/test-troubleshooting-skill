-- PostgreSQL Replication Monitoring Queries
-- Compatible with PostgreSQL 14-17
-- Usage: kubectl exec -n <ns> <master-pod> -- psql -U postgres -d postgres -f /dev/stdin < replication.sql

-- ============================================================================
-- Replication Role Check
-- ============================================================================

SELECT
    pg_is_in_recovery() AS is_replica,
    CASE WHEN pg_is_in_recovery() THEN 'REPLICA' ELSE 'PRIMARY' END AS role,
    pg_last_wal_receive_lsn() AS receive_lsn,
    pg_last_wal_replay_lsn() AS replay_lsn,
    pg_last_xact_replay_timestamp() AS last_replay_time;

-- ============================================================================
-- Replication Connections (from primary)
-- ============================================================================

SELECT
    pid,
    application_name,
    client_addr,
    state,
    sync_state,
    sent_lsn,
    write_lsn,
    flush_lsn,
    replay_lsn,
    pg_wal_lsn_diff(sent_lsn, replay_lsn) AS lag_bytes,
    pg_size_pretty(pg_wal_lsn_diff(sent_lsn, replay_lsn)) AS lag_size,
    CASE
        WHEN pg_wal_lsn_diff(sent_lsn, replay_lsn) IS NULL THEN 'UNKNOWN'
        WHEN pg_wal_lsn_diff(sent_lsn, replay_lsn) = 0 THEN 'SYNCED'
        WHEN pg_wal_lsn_diff(sent_lsn, replay_lsn) < 1048576 THEN 'LOW_LAG'
        WHEN pg_wal_lsn_diff(sent_lsn, replay_lsn) < 104857600 THEN 'MEDIUM_LAG'
        ELSE 'HIGH_LAG'
    END AS lag_status,
    now() - backend_start AS connection_age
FROM pg_stat_replication
ORDER BY lag_bytes DESC NULLS LAST;

-- ============================================================================
-- Replication Slots
-- ============================================================================

SELECT
    slot_name,
    slot_type,
    active,
    active_pid,
    database,
    restart_lsn,
    confirmed_flush_lsn,
    CASE
        WHEN NOT pg_is_in_recovery() THEN pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)
    END AS lag_bytes,
    CASE
        WHEN NOT pg_is_in_recovery() THEN pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn))
    END AS lag_size,
    CASE
        WHEN NOT active THEN 'INACTIVE_SLOT'
        WHEN NOT pg_is_in_recovery() AND pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) > 1073741824 THEN 'HIGH_WAL_ACCUMULATION'
        ELSE 'OK'
    END AS slot_status
FROM pg_replication_slots
ORDER BY lag_bytes DESC NULLS LAST;

-- ============================================================================
-- WAL Statistics
-- ============================================================================

SELECT
    pg_walfile_name(pg_current_wal_lsn()) AS current_wal_file,
    pg_current_wal_insert_lsn() AS insert_lsn,
    pg_current_wal_flush_lsn() AS flush_lsn,
    (SELECT count(*) FROM pg_ls_waldir()) AS wal_files_count,
    (SELECT pg_size_pretty(sum(size)) FROM pg_ls_waldir()) AS total_wal_size
WHERE NOT pg_is_in_recovery();

-- ============================================================================
-- WAL Archive Status
-- ============================================================================

SELECT
    archived_count,
    failed_count,
    last_archived_wal,
    last_archived_time,
    last_failed_wal,
    last_failed_time,
    CASE
        WHEN archived_count = 0 AND last_failed_wal IS NOT NULL THEN 'CRITICAL'
        WHEN failed_count > 0 THEN 'WARNING'
        ELSE 'OK'
    END AS archive_status
FROM pg_stat_archiver;

-- ============================================================================
-- Replication Configuration
-- ============================================================================

SELECT name, setting, unit
FROM pg_settings
WHERE name IN (
    'max_wal_senders',
    'max_replication_slots',
    'wal_level',
    'wal_keep_size',
    'max_slot_wal_keep_size',
    'hot_standby',
    'hot_standby_feedback',
    'wal_sender_timeout',
    'wal_receiver_timeout',
    'synchronous_commit',
    'synchronous_standby_names'
)
ORDER BY name;

-- ============================================================================
-- Patroni Replication Summary
-- ============================================================================

SELECT
    COUNT(*) AS total_replicas,
    COUNT(*) FILTER (WHERE sync_state = 'sync') AS sync_replicas,
    COUNT(*) FILTER (WHERE sync_state = 'async') AS async_replicas,
    COUNT(*) FILTER (WHERE sync_state = 'potential') AS potential_replicas,
    pg_size_pretty(AVG(pg_wal_lsn_diff(sent_lsn, replay_lsn))::bigint) AS avg_lag,
    pg_size_pretty(MAX(pg_wal_lsn_diff(sent_lsn, replay_lsn))) AS max_lag
FROM pg_stat_replication;

-- ============================================================================
-- Inactive Slots Warning (WAL bloat risk)
-- ============================================================================

SELECT
    slot_name,
    database,
    pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS wal_retained
FROM pg_replication_slots
WHERE NOT active
  AND NOT pg_is_in_recovery()
ORDER BY pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) DESC;
