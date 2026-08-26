-- Which non-drawing hosted effects were costly, copied data, or failed?
-- Requires standard or full detail. Draw operations are intentionally absent;
-- use rendering.sql with a full capture for individual draw detail.
WITH evidence AS (
    SELECT status, reason FROM measurement_status WHERE name = 'hosted_effects'
), data AS (
    SELECT name,
           CASE kind WHEN 1 THEN 'init!' WHEN 2 THEN 'update!'
                     WHEN 3 THEN 'render!' WHEN 4 THEN 'task' ELSE 'unknown' END AS phase,
           count(*) AS calls,
           avg(duration_ns) AS mean_ns,
           max(duration_ns) AS max_ns,
           sum(value_b <> 0) AS non_success,
           sum(value_a) AS inbound_copied_bytes,
           sum(outbound_copied_bytes) AS outbound_copied_bytes,
           sum(ownership_transfer_bytes) AS ownership_transfer_bytes,
           sum(worker_ns) AS worker_ns,
           sum(external_ns) AS external_ns,
           sum(worker_ns IS NULL) AS unavailable_worker_intervals,
           sum(external_ns IS NULL) AS unavailable_external_intervals
    FROM hosted_effects GROUP BY name, kind
)
SELECT evidence.status AS evidence_status,
       CASE WHEN evidence.status = 'complete' AND data.name IS NULL
            THEN 'complete evidence; no non-drawing hosted effects observed'
            ELSE evidence.reason END AS evidence_reason,
       data.name, data.phase, data.calls,
       data.mean_ns, data.mean_ns / 1000000.0 AS mean_ms,
       data.max_ns, data.max_ns / 1000000.0 AS max_ms,
       data.non_success, data.inbound_copied_bytes,
       data.outbound_copied_bytes, data.ownership_transfer_bytes,
       data.worker_ns, data.worker_ns / 1000000.0 AS worker_ms,
       data.external_ns, data.external_ns / 1000000.0 AS external_ms,
       data.unavailable_worker_intervals, data.unavailable_external_intervals
FROM evidence LEFT JOIN data ON evidence.status = 'complete'
ORDER BY data.max_ns DESC, data.name;
