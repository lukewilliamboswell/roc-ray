-- Did any bounded queue saturate or any intentionally lossy input overflow?
-- Requires standard or full detail. Capacity zero means application-proportional
-- work with no platform refusal cap, as documented by the facility.
WITH evidence AS (
    SELECT status, reason FROM measurement_status WHERE name = 'queue_pressure'
), data AS (
    SELECT name, sum(kind = 2) AS saturation_events,
           sum(kind = 3) AS overflow_events,
           max(subject_id) AS high_water,
           max(parent_id) AS capacity,
           max(duration_ns) AS oldest_age_ns
    FROM queue_pressure GROUP BY name
)
SELECT evidence.status AS evidence_status,
       CASE WHEN evidence.status = 'complete' AND data.name IS NULL
            THEN 'complete evidence; no queue activity observed' ELSE evidence.reason END AS evidence_reason,
       data.name, data.saturation_events, data.overflow_events,
       data.high_water, data.capacity,
       data.oldest_age_ns, data.oldest_age_ns / 1000000.0 AS oldest_age_ms
FROM evidence LEFT JOIN data ON evidence.status = 'complete'
ORDER BY data.saturation_events DESC, data.overflow_events DESC, data.name;
