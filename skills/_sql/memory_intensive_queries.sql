-- memory_intensive_queries.sql
-- Identify queries that may be consuming excessive memory
-- Run this after detecting OOM kills or high memory usage
--
-- For memory configuration review, see: configuration.sql (Memory Settings section)
-- For table bloat analysis, see: bloat_estimation.sql
-- For vacuum health, see: performance.sql (Vacuum & Analyze Health section)
-- For total memory requirement estimates, see: memory_requirements.sql
--
-- Compatible with PostgreSQL 14-17
-- Usage: kubectl exec -i -n <ns> <master-pod> -- psql -U postgres -d postgres -f /dev/stdin < memory_intensive_queries.sql

-- ============================================================================
-- Active Queries with Memory Risk Classification
-- ============================================================================
-- Flags long-running queries and those waiting on buffer/disk I/O,
-- which are the most likely to consume or pressure memory.

SELECT
    pid,
    usename,
    datname,
    state,
    left(query, 100) AS query_partial,
    age(clock_timestamp(), query_start) AS duration,
    wait_event_type,
    wait_event,
    CASE
        WHEN state = 'active' AND query_start < clock_timestamp() - interval '5 minutes'
        THEN 'LONG_RUNNING'
        WHEN wait_event_type = 'LWLock' AND wait_event LIKE '%buffer%'
        THEN 'BUFFER_CONTENTION'
        WHEN wait_event_type = 'IO'
        THEN 'DISK_IO'
        ELSE 'NORMAL'
    END AS memory_risk
FROM pg_stat_activity
WHERE state != 'idle'
  AND pid <> pg_backend_pid()
ORDER BY query_start ASC NULLS LAST
LIMIT 20;

-- ============================================================================
-- Queries Spilling to Disk (requires pg_stat_statements)
-- ============================================================================
-- High temp_blks_read/written means sorts or hash joins exceeded work_mem
-- and spilled to temporary files. These are prime candidates for work_mem
-- tuning or query optimization.

SELECT
    queryid,
    left(query, 120) AS query_partial,
    calls,
    round(mean_exec_time::numeric, 2) AS avg_ms,
    rows,
    temp_blks_read + temp_blks_written AS temp_blocks_total,
    pg_size_pretty((temp_blks_read + temp_blks_written) * 8192) AS temp_bytes_total,
    round((temp_blks_read + temp_blks_written)::numeric / NULLIF(calls, 0), 1) AS temp_blocks_per_call
FROM pg_stat_statements
WHERE temp_blks_read + temp_blks_written > 0
ORDER BY temp_blks_read + temp_blks_written DESC
LIMIT 15;

-- ============================================================================
-- Per-Backend Memory Contexts (PostgreSQL 14+)
-- ============================================================================
-- Shows memory allocated by the heaviest backends. Only visible for
-- the current backend by default; superuser can see all via
-- pg_backend_memory_contexts or pg_log_backend_memory_contexts().

SELECT
    pid,
    usename,
    datname,
    state,
    left(query, 80) AS query_partial,
    age(clock_timestamp(), backend_start) AS backend_age,
    age(clock_timestamp(), query_start) AS query_duration
FROM pg_stat_activity
WHERE backend_type = 'client backend'
  AND state = 'active'
  AND pid <> pg_backend_pid()
ORDER BY query_start ASC NULLS LAST;

-- To inspect a specific backend's memory, run as superuser:
-- SELECT * FROM pg_log_backend_memory_contexts(<pid>);
-- Then check the server log for the output.
