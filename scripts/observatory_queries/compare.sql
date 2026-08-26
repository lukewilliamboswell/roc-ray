-- Are two captures mechanically comparable, and how did cycle/allocation cost change?
-- Open the before capture as the main database and attach the after capture as
-- `after` in read-only mode before reading this file. Matching application,
-- environment, detail, recorder configuration, and complete evidence do not
-- prove workload equivalence; use the same scripted workload for both runs.
WITH checks AS (
    SELECT
      (SELECT value FROM main.metadata WHERE key = 'schema_version') = '1'
      AND (SELECT value FROM after.metadata WHERE key = 'schema_version') = '1' AS schema_ok,
      (SELECT value FROM main.metadata WHERE key = 'clean_shutdown') = '1'
      AND (SELECT value FROM after.metadata WHERE key = 'clean_shutdown') = '1'
      AND (SELECT value FROM main.metadata WHERE key = 'final_state') = 'complete'
      AND (SELECT value FROM after.metadata WHERE key = 'final_state') = 'complete'
      AND (SELECT writer_failed + output_limited + omitted_events FROM main.recorder_health WHERE id = 1) = 0
      AND (SELECT writer_failed + output_limited + omitted_events FROM after.recorder_health WHERE id = 1) = 0 AS captures_ok,
      (SELECT status FROM main.measurement_status WHERE name = 'cycle_summary') = 'complete'
      AND (SELECT status FROM after.measurement_status WHERE name = 'cycle_summary') = 'complete'
      AND (SELECT status FROM main.measurement_status WHERE name = 'allocation_counters') = 'complete'
      AND (SELECT status FROM after.measurement_status WHERE name = 'allocation_counters') = 'complete' AS evidence_ok,
      (SELECT value FROM main.metadata WHERE key = 'app_name') = (SELECT value FROM after.metadata WHERE key = 'app_name') AS app_ok,
      (SELECT value FROM main.metadata WHERE key = 'target_profile') = (SELECT value FROM after.metadata WHERE key = 'target_profile')
      AND (SELECT value FROM main.metadata WHERE key = 'backend') = (SELECT value FROM after.metadata WHERE key = 'backend')
      AND (SELECT value FROM main.metadata WHERE key = 'host_os') = (SELECT value FROM after.metadata WHERE key = 'host_os')
      AND (SELECT value FROM main.metadata WHERE key = 'host_arch') = (SELECT value FROM after.metadata WHERE key = 'host_arch') AS environment_ok,
      (SELECT value FROM main.metadata WHERE key = 'effective_detail') = (SELECT value FROM after.metadata WHERE key = 'effective_detail')
      AND (SELECT value FROM main.metadata WHERE key = 'chunk_count') = (SELECT value FROM after.metadata WHERE key = 'chunk_count')
      AND (SELECT value FROM main.metadata WHERE key = 'summary_reserve') = (SELECT value FROM after.metadata WHERE key = 'summary_reserve')
      AND (SELECT value FROM main.metadata WHERE key = 'transaction_chunks') = (SELECT value FROM after.metadata WHERE key = 'transaction_chunks')
      AND (SELECT value FROM main.metadata WHERE key = 'max_output_bytes') = (SELECT value FROM after.metadata WHERE key = 'max_output_bytes')
      AND (SELECT value FROM main.metadata WHERE key = 'benchmark_writer_delay_ms') = (SELECT value FROM after.metadata WHERE key = 'benchmark_writer_delay_ms') AS recorder_ok
), before_ranked AS (
    SELECT duration_ns, row_number() OVER (ORDER BY duration_ns) n, count(*) OVER () c FROM main.cycles
), after_ranked AS (
    SELECT duration_ns, row_number() OVER (ORDER BY duration_ns) n, count(*) OVER () c FROM after.cycles
), before_values AS (
    SELECT count(*) AS cycles, (SELECT avg(alloc_bytes) FROM main.cycles) AS alloc_bytes_per_cycle,
           max(CASE WHEN n = (c + 1) / 2 THEN duration_ns END) AS median_ns,
           max(CASE WHEN n = (c * 95 + 99) / 100 THEN duration_ns END) AS p95_ns,
           max(CASE WHEN n = (c * 99 + 99) / 100 THEN duration_ns END) AS p99_ns
    FROM before_ranked
), after_values AS (
    SELECT count(*) AS cycles, (SELECT avg(alloc_bytes) FROM after.cycles) AS alloc_bytes_per_cycle,
           max(CASE WHEN n = (c + 1) / 2 THEN duration_ns END) AS median_ns,
           max(CASE WHEN n = (c * 95 + 99) / 100 THEN duration_ns END) AS p95_ns,
           max(CASE WHEN n = (c * 99 + 99) / 100 THEN duration_ns END) AS p99_ns
    FROM after_ranked
), verdict AS (
    SELECT *, schema_ok AND captures_ok AND evidence_ok AND app_ok AND environment_ok AND recorder_ok AS comparable,
      CASE WHEN NOT schema_ok THEN 'schema version differs or is unsupported'
           WHEN NOT captures_ok THEN 'one or both captures are untrusted or incomplete'
           WHEN NOT evidence_ok THEN 'required measurement evidence is incomplete'
           WHEN NOT app_ok THEN 'application identity differs'
           WHEN NOT environment_ok THEN 'target, backend, operating system, or architecture differs'
           WHEN NOT recorder_ok THEN 'detail level or recorder configuration differs'
           ELSE 'mechanically comparable; workload equivalence remains the caller responsibility' END AS reason
    FROM checks
)
SELECT CASE WHEN verdict.comparable THEN 'complete' ELSE 'incomparable' END AS evidence_status,
       verdict.reason AS evidence_reason,
       before_values.cycles AS before_cycles, after_values.cycles AS after_cycles,
       CASE WHEN verdict.comparable THEN after_values.median_ns - before_values.median_ns END AS median_delta_ns,
       CASE WHEN verdict.comparable THEN (after_values.median_ns - before_values.median_ns) / 1000000.0 END AS median_delta_ms,
       CASE WHEN verdict.comparable THEN after_values.p95_ns - before_values.p95_ns END AS p95_delta_ns,
       CASE WHEN verdict.comparable THEN (after_values.p95_ns - before_values.p95_ns) / 1000000.0 END AS p95_delta_ms,
       CASE WHEN verdict.comparable THEN after_values.p99_ns - before_values.p99_ns END AS p99_delta_ns,
       CASE WHEN verdict.comparable THEN (after_values.p99_ns - before_values.p99_ns) / 1000000.0 END AS p99_delta_ms,
       CASE WHEN verdict.comparable THEN after_values.alloc_bytes_per_cycle - before_values.alloc_bytes_per_cycle END AS allocation_bytes_per_cycle_delta
FROM verdict CROSS JOIN before_values CROSS JOIN after_values;
