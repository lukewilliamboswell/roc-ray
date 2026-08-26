-- Were host resources saturated, retained, or slow to destroy after retirement?
-- Requires standard or full detail. Individual resource uses are deliberately
-- not recorded; cycles.resource_events retains their per-cycle aggregate count.
WITH evidence AS (
    SELECT status, reason FROM measurement_status WHERE name = 'resource_lifecycle'
), data AS (
    SELECT subject_id, name,
           sum(kind = 0) AS created,
           sum(kind = 1) AS saturation_events,
           sum(kind = 2) AS retired,
           sum(kind = 3) AS destroyed,
           sum(kind = 5) AS reused,
           max(CASE WHEN kind = 3 THEN duration_ns END) AS destruction_delay_ns,
           max(value_b) AS heap_high_water
    FROM resource_lifecycle GROUP BY subject_id, name
)
SELECT evidence.status AS evidence_status,
       CASE WHEN evidence.status = 'complete' AND data.name IS NULL
            THEN 'complete evidence; no resource lifecycle activity observed' ELSE evidence.reason END AS evidence_reason,
       data.subject_id, data.name, data.created, data.saturation_events,
       data.retired, data.destroyed, data.reused,
       CASE WHEN data.created > 0 AND data.destroyed = 0 THEN 1 ELSE 0 END AS retained_at_shutdown,
       data.destruction_delay_ns,
       data.destruction_delay_ns / 1000000.0 AS destruction_delay_ms,
       data.heap_high_water
FROM evidence LEFT JOIN data ON evidence.status = 'complete'
ORDER BY retained_at_shutdown DESC, data.destruction_delay_ns DESC, data.subject_id;
