WITH evidence AS (SELECT status,reason FROM measurement_status WHERE name='cycle_summary')
SELECT evidence.status AS evidence_status,evidence.reason AS evidence_reason,cycle,duration_ns,update_ns,render_callback_ns,task_executor_ns,host_other_ns
FROM evidence LEFT JOIN cycles ON evidence.status='complete' ORDER BY duration_ns DESC,cycle LIMIT :limit;
