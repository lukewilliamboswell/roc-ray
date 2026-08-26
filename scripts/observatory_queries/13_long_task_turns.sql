WITH evidence AS (SELECT status,reason FROM measurement_status WHERE name='task_lifecycle'),
ordered AS (SELECT subject_id,kind,timestamp_ns,lead(timestamp_ns) OVER(PARTITION BY subject_id ORDER BY timestamp_ns,id) ended_ns,lead(kind) OVER(PARTITION BY subject_id ORDER BY timestamp_ns,id) ended_kind FROM task_events),
turns AS (SELECT * FROM ordered WHERE kind IN (2,4) AND ended_kind IN (3,5,7))
SELECT evidence.status AS evidence_status,evidence.reason AS evidence_reason,subject_id,timestamp_ns AS started_ns,ended_ns-timestamp_ns AS active_ns
FROM evidence LEFT JOIN turns ON evidence.status='complete' ORDER BY active_ns DESC,subject_id LIMIT :limit;
