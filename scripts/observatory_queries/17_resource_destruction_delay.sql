WITH evidence AS (SELECT status,reason FROM measurement_status WHERE name='resource_lifecycle'), data AS (
 SELECT subject_id,name,max(CASE WHEN kind=3 THEN duration_ns END) destruction_delay_ns,max(value_b) heap_high_water FROM resource_lifecycle GROUP BY subject_id,name)
SELECT evidence.status evidence_status,evidence.reason evidence_reason,data.* FROM evidence LEFT JOIN data ON evidence.status='complete' ORDER BY destruction_delay_ns DESC,subject_id;
