WITH evidence AS (SELECT status,reason FROM measurement_status WHERE name='structural_latency')
SELECT evidence.status evidence_status,evidence.reason evidence_reason,subject_id,parent_id,cycle,duration_ns FROM evidence LEFT JOIN structural_latency ON evidence.status='complete' AND kind=1 AND name='input_to_presentation' ORDER BY duration_ns DESC,id;
