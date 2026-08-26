-- Where did each task spend time between spawn, active turns, parks, and delivery?
-- Requires standard or full detail. Parked time is waiting, not Roc execution.
-- Results are the 20 tasks with the longest active turn.
WITH evidence AS (
    SELECT status, reason FROM measurement_status WHERE name = 'task_lifecycle'
), ordered AS (
    SELECT *, lead(timestamp_ns) OVER (PARTITION BY subject_id ORDER BY timestamp_ns, id) AS next_ns,
           lead(kind) OVER (PARTITION BY subject_id ORDER BY timestamp_ns, id) AS next_kind
    FROM task_events WHERE (SELECT status FROM evidence) = 'complete'
), data AS (
    SELECT subject_id,
           min(CASE WHEN kind = 0 THEN timestamp_ns END) AS spawned_ns,
           min(CASE WHEN kind = 2 THEN timestamp_ns END) AS started_ns,
           min(CASE WHEN kind = 5 THEN timestamp_ns END) AS finished_ns,
           min(CASE WHEN kind = 6 THEN timestamp_ns END) AS delivered_ns,
           min(CASE WHEN kind = 7 THEN timestamp_ns END) AS cancelled_ns,
           sum(CASE WHEN kind IN (2, 4) AND next_kind IN (3, 5, 7) THEN next_ns - timestamp_ns ELSE 0 END) AS active_ns,
           max(CASE WHEN kind IN (2, 4) AND next_kind IN (3, 5, 7) THEN next_ns - timestamp_ns ELSE 0 END) AS longest_turn_ns,
           sum(CASE WHEN kind = 3 AND next_kind IN (4, 7) THEN next_ns - timestamp_ns ELSE 0 END) AS parked_ns
    FROM ordered GROUP BY subject_id
    ORDER BY longest_turn_ns DESC, subject_id LIMIT 20
)
SELECT evidence.status AS evidence_status,
       CASE WHEN evidence.status = 'complete' AND data.subject_id IS NULL
            THEN 'complete evidence; no tasks observed' ELSE evidence.reason END AS evidence_reason,
       data.subject_id,
       CASE WHEN data.delivered_ns IS NOT NULL THEN 'delivered'
            WHEN data.cancelled_ns IS NOT NULL THEN 'cancelled'
            WHEN data.finished_ns IS NOT NULL THEN 'finished, not delivered'
            ELSE 'unfinished' END AS outcome,
       data.spawned_ns, data.started_ns, data.finished_ns, data.delivered_ns, data.cancelled_ns,
       data.started_ns - data.spawned_ns AS start_delay_ns,
       (data.started_ns - data.spawned_ns) / 1000000.0 AS start_delay_ms,
       data.active_ns, data.active_ns / 1000000.0 AS active_ms,
       data.parked_ns, data.parked_ns / 1000000.0 AS parked_ms,
       data.longest_turn_ns, data.longest_turn_ns / 1000000.0 AS longest_turn_ms,
       data.delivered_ns - data.finished_ns AS delivery_delay_ns,
       (data.delivered_ns - data.finished_ns) / 1000000.0 AS delivery_delay_ms
FROM evidence LEFT JOIN data ON evidence.status = 'complete';
