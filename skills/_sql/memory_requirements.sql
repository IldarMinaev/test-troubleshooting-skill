-- memory_requirements.sql
-- Calculate PostgreSQL memory requirements based on current configuration
-- Helps estimate if Kubernetes memory limits are sufficient

SELECT 
  'PostgreSQL Memory Requirements' as analysis,
  'Minimum safe memory (worst-case)' as scenario,
  pg_size_pretty((
    -- shared_buffers
    (SELECT setting::bigint FROM pg_settings WHERE name = 'shared_buffers') * 1024 +
    -- work_mem for all connections (worst case)
    (SELECT setting::bigint FROM pg_settings WHERE name = 'work_mem') * 1024 * 
    (SELECT setting::bigint FROM pg_settings WHERE name = 'max_connections') +
    -- maintenance_work_mem for all autovacuum workers (could be vacuum + analyze)
    (SELECT setting::bigint FROM pg_settings WHERE name = 'maintenance_work_mem') * 1024 * 
    (SELECT setting::bigint FROM pg_settings WHERE name = 'autovacuum_max_workers') * 2 +
    -- PostgreSQL base overhead (shared memory, wal buffers, etc)
    100 * 1024 * 1024
  )) as estimated_minimum_bytes
UNION ALL
SELECT 
  'PostgreSQL Memory Requirements',
  'Typical memory (average load)',
  pg_size_pretty((
    -- shared_buffers
    (SELECT setting::bigint FROM pg_settings WHERE name = 'shared_buffers') * 1024 +
    -- work_mem for 25% of connections
    (SELECT setting::bigint FROM pg_settings WHERE name = 'work_mem') * 1024 * 
    (SELECT setting::bigint FROM pg_settings WHERE name = 'max_connections') * 0.25 +
    -- maintenance_work_mem for half workers
    (SELECT setting::bigint FROM pg_settings WHERE name = 'maintenance_work_mem') * 1024 * 
    (SELECT setting::bigint FROM pg_settings WHERE name = 'autovacuum_max_workers') * 0.5 +
    -- PostgreSQL base overhead
    100 * 1024 * 1024
  ))
UNION ALL
SELECT 
  'Current Configuration',
  'Parameter values',
  CONCAT(
    'shared_buffers: ', (SELECT setting FROM pg_settings WHERE name = 'shared_buffers'), 'kB, ',
    'work_mem: ', (SELECT setting FROM pg_settings WHERE name = 'work_mem'), 'kB, ',
    'max_connections: ', (SELECT setting FROM pg_settings WHERE name = 'max_connections'), ', ',
    'maintenance_work_mem: ', (SELECT setting FROM pg_settings WHERE name = 'maintenance_work_mem'), 'kB, ',
    'autovacuum_max_workers: ', (SELECT setting FROM pg_settings WHERE name = 'autovacuum_max_workers')
  )
UNION ALL
SELECT 
  'Memory Breakdown',
  'shared_buffers',
  pg_size_pretty((SELECT setting::bigint FROM pg_settings WHERE name = 'shared_buffers') * 1024)
UNION ALL
SELECT 
  'Memory Breakdown',
  'work_mem * max_connections (worst case)',
  pg_size_pretty(
    (SELECT setting::bigint FROM pg_settings WHERE name = 'work_mem') * 1024 * 
    (SELECT setting::bigint FROM pg_settings WHERE name = 'max_connections')
  )
UNION ALL
SELECT 
  'Memory Breakdown',
  'maintenance_work_mem * autovacuum_max_workers * 2',
  pg_size_pretty(
    (SELECT setting::bigint FROM pg_settings WHERE name = 'maintenance_work_mem') * 1024 * 
    (SELECT setting::bigint FROM pg_settings WHERE name = 'autovacuum_max_workers') * 2
  )
UNION ALL
SELECT 
  'Risk Assessment',
  CASE 
    WHEN (
      (SELECT setting::bigint FROM pg_settings WHERE name = 'shared_buffers') * 1024 +
      (SELECT setting::bigint FROM pg_settings WHERE name = 'work_mem') * 1024 * 
      (SELECT setting::bigint FROM pg_settings WHERE name = 'max_connections') +
      (SELECT setting::bigint FROM pg_settings WHERE name = 'maintenance_work_mem') * 1024 * 
      (SELECT setting::bigint FROM pg_settings WHERE name = 'autovacuum_max_workers') * 2 +
      100 * 1024 * 1024
    ) > 500 * 1024 * 1024 THEN 'HIGH: Estimated >500Mi (OOM risk)'
    WHEN (
      (SELECT setting::bigint FROM pg_settings WHERE name = 'shared_buffers') * 1024 +
      (SELECT setting::bigint FROM pg_settings WHERE name = 'work_mem') * 1024 * 
      (SELECT setting::bigint FROM pg_settings WHERE name = 'max_connections') +
      (SELECT setting::bigint FROM pg_settings WHERE name = 'maintenance_work_mem') * 1024 * 
      (SELECT setting::bigint FROM pg_settings WHERE name = 'autovacuum_max_workers') * 2 +
      100 * 1024 * 1024
    ) > 400 * 1024 * 1024 THEN 'MEDIUM: Close to 500Mi limit'
    ELSE 'LOW: Well within 500Mi limit'
  END,
  'Based on 500Mi Kubernetes limit'
ORDER BY 
  CASE analysis 
    WHEN 'PostgreSQL Memory Requirements' THEN 1
    WHEN 'Current Configuration' THEN 2
    WHEN 'Memory Breakdown' THEN 3
    WHEN 'Risk Assessment' THEN 4
  END,
  scenario;