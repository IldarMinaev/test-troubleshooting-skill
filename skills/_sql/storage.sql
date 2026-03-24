-- PostgreSQL Storage Analysis Queries
-- Compatible with PostgreSQL 14-17
-- Usage: kubectl exec -n <ns> <master-pod> -- psql -U postgres -d postgres -f /dev/stdin < storage.sql

-- ============================================================================
-- Database Sizes
-- ============================================================================

SELECT
    datname,
    pg_size_pretty(pg_database_size(datname)) AS size,
    pg_database_size(datname) AS size_bytes
FROM pg_database
WHERE datallowconn = true
ORDER BY pg_database_size(datname) DESC;

-- ============================================================================
-- Top 20 Tables by Size
-- ============================================================================

SELECT
    schemaname,
    relname AS table_name,
    pg_size_pretty(pg_total_relation_size(schemaname || '.' || relname)) AS total_size,
    pg_size_pretty(pg_relation_size(schemaname || '.' || relname)) AS table_size,
    pg_size_pretty(pg_total_relation_size(schemaname || '.' || relname) - pg_relation_size(schemaname || '.' || relname)) AS index_size,
    n_live_tup AS live_rows,
    n_dead_tup AS dead_rows
FROM pg_stat_user_tables
ORDER BY pg_total_relation_size(schemaname || '.' || relname) DESC
LIMIT 20;

-- ============================================================================
-- Top 20 Indexes by Size
-- ============================================================================

SELECT
    schemaname,
    relname AS table_name,
    indexrelname AS index_name,
    pg_size_pretty(pg_relation_size(schemaname || '.' || indexrelname)) AS index_size,
    idx_scan AS scans,
    CASE WHEN idx_scan = 0 THEN 'UNUSED' ELSE 'ACTIVE' END AS usage
FROM pg_stat_user_indexes
ORDER BY pg_relation_size(schemaname || '.' || indexrelname) DESC
LIMIT 20;

-- ============================================================================
-- WAL Directory Size
-- ============================================================================

SELECT
    count(*) AS wal_files,
    pg_size_pretty(sum(size)) AS total_wal_size
FROM pg_ls_waldir();

-- ============================================================================
-- Temporary Files
-- ============================================================================

SELECT
    datname,
    temp_files,
    pg_size_pretty(temp_bytes) AS temp_bytes
FROM pg_stat_database
WHERE temp_files > 0
ORDER BY temp_bytes DESC;

-- ============================================================================
-- Tablespace Usage
-- ============================================================================

SELECT
    spcname AS tablespace,
    pg_size_pretty(pg_tablespace_size(spcname)) AS size
FROM pg_tablespace
ORDER BY pg_tablespace_size(spcname) DESC;

-- ============================================================================
-- Schema Sizes
-- ============================================================================

SELECT
    schemaname,
    count(*) AS table_count,
    pg_size_pretty(sum(pg_total_relation_size(schemaname || '.' || relname))) AS total_size
FROM pg_stat_user_tables
GROUP BY schemaname
ORDER BY sum(pg_total_relation_size(schemaname || '.' || relname)) DESC;

-- ============================================================================
-- TOAST Table Sizes (large objects)
-- ============================================================================

SELECT
    c.relname AS table_name,
    pg_size_pretty(pg_relation_size(c.reltoastrelid)) AS toast_size
FROM pg_class c
WHERE c.reltoastrelid <> 0
  AND c.relkind = 'r'
  AND c.relnamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'public')
  AND pg_relation_size(c.reltoastrelid) > 1048576
ORDER BY pg_relation_size(c.reltoastrelid) DESC
LIMIT 10;

-- ============================================================================
-- Total Data Directory Size Estimate
-- ============================================================================

SELECT
    pg_size_pretty(sum(pg_database_size(datname))) AS total_all_databases,
    (SELECT pg_size_pretty(sum(size)) FROM pg_ls_waldir()) AS total_wal
FROM pg_database
WHERE datallowconn = true;
