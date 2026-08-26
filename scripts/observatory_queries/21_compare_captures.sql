WITH checks AS (
 SELECT
  (SELECT status FROM before.measurement_status WHERE name='cycle_summary')='complete'
  AND (SELECT status FROM after.measurement_status WHERE name='cycle_summary')='complete'
  AND (SELECT value FROM before.metadata WHERE key='schema_version')=(SELECT value FROM after.metadata WHERE key='schema_version')
  AND (SELECT value FROM before.metadata WHERE key='target_profile')=(SELECT value FROM after.metadata WHERE key='target_profile')
  AND (SELECT value FROM before.metadata WHERE key='backend')=(SELECT value FROM after.metadata WHERE key='backend')
  AND (SELECT value FROM before.metadata WHERE key='host_os')=(SELECT value FROM after.metadata WHERE key='host_os')
  AND (SELECT value FROM before.metadata WHERE key='host_arch')=(SELECT value FROM after.metadata WHERE key='host_arch')
  AND (SELECT value FROM before.metadata WHERE key='effective_detail')=(SELECT value FROM after.metadata WHERE key='effective_detail') AS compatible),
b AS (SELECT count(*) cycles,avg(duration_ns) mean_ns,avg(alloc_bytes) alloc_bytes_per_cycle FROM before.cycles),
a AS (SELECT count(*) cycles,avg(duration_ns) mean_ns,avg(alloc_bytes) alloc_bytes_per_cycle FROM after.cycles)
SELECT CASE WHEN compatible THEN 'complete' ELSE 'incomparable' END AS evidence_status,
       CASE WHEN compatible THEN 'mechanically compatible; workload equivalence is the caller responsibility' ELSE 'capture evidence or environment differs' END AS evidence_reason,
       b.cycles AS before_cycles,a.cycles AS after_cycles,
       CASE WHEN compatible THEN a.mean_ns-b.mean_ns END AS mean_cycle_delta_ns,
       CASE WHEN compatible THEN a.alloc_bytes_per_cycle-b.alloc_bytes_per_cycle END AS allocation_bytes_per_cycle_delta
FROM checks,b,a;
