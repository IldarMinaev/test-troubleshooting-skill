-- PostgreSQL Configuration Review Queries
-- Compatible with PostgreSQL 14-17
-- Usage: kubectl exec -n <ns> <master-pod> -- psql -U postgres -d postgres -f /dev/stdin < configuration.sql

-- ============================================================================
-- Non-Default Settings
-- ============================================================================

SELECT
    name,
    setting,
    unit,
    source,
    sourcefile
FROM pg_settings
WHERE source NOT IN ('default', 'override')
ORDER BY source, name;

-- ============================================================================
-- Memory Settings
-- ============================================================================

SELECT
    name,
    setting,
    unit,
    pg_size_pretty(
        setting::bigint *
        CASE unit
            WHEN '8kB' THEN 8192
            WHEN 'kB' THEN 1024
            WHEN 'MB' THEN 1048576
            WHEN 'GB' THEN 1073741824
            ELSE 1
        END
    ) AS human_readable,
    CASE
        WHEN name = 'shared_buffers' AND unit = '8kB' AND setting::bigint * 8192 < 134217728 THEN 'LOW (<128MB)'
        WHEN name = 'work_mem' AND unit = 'kB' AND setting::integer < 4096 THEN 'LOW (<4MB)'
        WHEN name = 'maintenance_work_mem' AND unit = 'kB' AND setting::integer < 65536 THEN 'LOW (<64MB)'
        ELSE 'OK'
    END AS recommendation
FROM pg_settings
WHERE name IN ('shared_buffers', 'work_mem', 'maintenance_work_mem', 'effective_cache_size', 'wal_buffers', 'temp_buffers')
  AND unit IN ('8kB', 'kB', 'MB', 'GB')
ORDER BY name;

-- ============================================================================
-- WAL Settings
-- ============================================================================

SELECT
    name,
    setting,
    unit
FROM pg_settings
WHERE name IN (
    'wal_level',
    'max_wal_size',
    'min_wal_size',
    'wal_keep_size',
    'max_slot_wal_keep_size',
    'checkpoint_timeout',
    'checkpoint_completion_target',
    'archive_mode',
    'archive_command',
    'archive_timeout'
)
ORDER BY name;

-- ============================================================================
-- Autovacuum Parameters
-- ============================================================================

SELECT
    name,
    setting,
    unit,
    short_desc
FROM pg_settings
WHERE name LIKE 'autovacuum%'
ORDER BY name;

-- ============================================================================
-- Connection Settings
-- ============================================================================

SELECT
    name,
    setting,
    unit,
    CASE
        WHEN name = 'max_connections' AND setting::integer < 100 THEN 'LOW'
        WHEN name = 'max_connections' AND setting::integer > 1000 THEN 'HIGH (consider connection pooling)'
        ELSE 'OK'
    END AS recommendation
FROM pg_settings
WHERE name IN (
    'max_connections',
    'superuser_reserved_connections',
    'idle_in_transaction_session_timeout',
    'statement_timeout',
    'lock_timeout',
    'tcp_keepalives_idle',
    'tcp_keepalives_interval',
    'tcp_keepalives_count'
)
ORDER BY name;

-- ============================================================================
-- Replication Settings
-- ============================================================================

SELECT name, setting, unit
FROM pg_settings
WHERE name IN (
    'max_wal_senders',
    'max_replication_slots',
    'synchronous_commit',
    'synchronous_standby_names',
    'hot_standby',
    'hot_standby_feedback'
)
ORDER BY name;

-- ============================================================================
-- Logging Settings
-- ============================================================================

SELECT name, setting, unit
FROM pg_settings
WHERE name IN (
    'log_destination',
    'log_min_duration_statement',
    'log_min_messages',
    'log_min_error_statement',
    'log_checkpoints',
    'log_connections',
    'log_disconnections',
    'log_lock_waits',
    'log_temp_files',
    'log_autovacuum_min_duration',
    'log_statement'
)
ORDER BY name;

-- ============================================================================
-- Extensions Installed
-- ============================================================================

SELECT
    extname AS extension,
    extversion AS version
FROM pg_extension
ORDER BY extname;

-- ============================================================================
-- PostgreSQL Version Info
-- ============================================================================

SELECT
    version() AS full_version,
    current_setting('server_version') AS version,
    current_setting('server_version_num') AS version_num,
    pg_postmaster_start_time() AS started_at,
    now() - pg_postmaster_start_time() AS uptime;
