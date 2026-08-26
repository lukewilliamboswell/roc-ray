WITH evidence AS (SELECT status,reason FROM measurement_status WHERE name='task_lifecycle'), data AS (
 SELECT subject_id,min(CASE WHEN kind=0 THEN timestamp_ns END) spawned_ns,min(CASE WHEN kind=2 THEN timestamp_ns END) started_ns,min(CASE WHEN kind=5 THEN timestamp_ns END) finished_ns,min(CASE WHEN kind=6 THEN timestamp_ns END) delivered_ns FROM task_events GROUP BY subject_id)
SELECT evidence.status evidence_status,evidence.reason evidence_reason,data.* FROM evidence LEFT JOIN data ON evidence.status='complete' ORDER BY subject_id;
