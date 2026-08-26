-- How much rendering work crossed the public boundary, and what was it?
-- Cycle aggregates work at every detail level. Named operation rows require
-- full detail. Aggregate and operation rows remain separate and are never
-- summed together. Host duration is callback/host-call wall time, not GPU time.
WITH evidence AS (
    SELECT status, reason FROM measurement_status WHERE name = 'draw_observations'
), detail AS (
    SELECT CASE WHEN (SELECT value FROM metadata WHERE key = 'effective_detail') = 'full'
                THEN 'complete' ELSE 'not_recorded' END AS status
), rows AS (
    SELECT 'cycle aggregate' AS record_type,
           'public_draw_effects' AS operation,
           'all accepted draw calls' AS category,
           count(*) AS observations,
           sum(value_a) AS accepted_calls,
           NULL AS items,
           NULL AS known_bytes,
           sum(duration_ns) AS host_duration_ns,
           max(duration_ns) AS max_host_duration_ns
    FROM draw_summaries
    WHERE name = 'public_draw_effects' AND (SELECT status FROM evidence) = 'complete'
    UNION ALL
    SELECT 'operation detail', name,
           CASE kind WHEN 0 THEN 'primitive' WHEN 1 THEN 'batch or instances'
                     WHEN 2 THEN 'upload' WHEN 3 THEN 'state change'
                     WHEN 4 THEN 'readback' WHEN 5 THEN 'render target change'
                     ELSE 'unknown' END,
           count(*), count(*), sum(value_a), sum(value_b),
           sum(duration_ns), max(duration_ns)
    FROM draw_summaries
    WHERE name <> 'public_draw_effects'
      AND (SELECT status FROM evidence) = 'complete'
      AND (SELECT status FROM detail) = 'complete'
    GROUP BY name, kind
)
SELECT evidence.status AS evidence_status, evidence.reason AS evidence_reason,
       detail.status AS operation_detail_status,
       rows.record_type, rows.operation, rows.category, rows.observations,
       rows.accepted_calls, rows.items, rows.known_bytes,
       rows.host_duration_ns, rows.host_duration_ns / 1000000.0 AS host_duration_ms,
       rows.max_host_duration_ns, rows.max_host_duration_ns / 1000000.0 AS max_host_duration_ms
FROM evidence CROSS JOIN detail
LEFT JOIN rows ON evidence.status = 'complete'
ORDER BY rows.record_type, rows.host_duration_ns DESC, rows.operation;
