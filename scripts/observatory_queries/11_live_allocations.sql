WITH latest AS (SELECT *,row_number() OVER(PARTITION BY subject_id ORDER BY timestamp_ns DESC,id DESC) n FROM allocation_events)
SELECT subject_id,bytes,phase,task_id,zone_id FROM latest WHERE n=1 AND kind<>1 ORDER BY bytes DESC,subject_id;
