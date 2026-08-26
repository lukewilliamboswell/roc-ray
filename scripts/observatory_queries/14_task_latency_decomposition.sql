SELECT subject_id,min(CASE WHEN kind=0 THEN timestamp_ns END) spawned_ns,min(CASE WHEN kind=2 THEN timestamp_ns END) started_ns,
 min(CASE WHEN kind=5 THEN timestamp_ns END) finished_ns,min(CASE WHEN kind=6 THEN timestamp_ns END) delivered_ns
FROM task_events GROUP BY subject_id ORDER BY subject_id;
