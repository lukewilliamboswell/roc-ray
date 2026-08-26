WITH evidence AS (SELECT status,reason FROM measurement_status WHERE name='allocation_lifecycle')
SELECT evidence.status evidence_status,evidence.reason evidence_reason,subject_id,cycle,timestamp_ns,prior_bytes,bytes,copied_bytes,phase,task_id,zone_id FROM evidence LEFT JOIN allocation_events ON evidence.status='complete' AND kind IN (2,3) ORDER BY copied_bytes DESC,id;
