WITH evidence AS (SELECT status,reason FROM measurement_status WHERE name='cycle_summary')
SELECT evidence.status AS evidence_status,evidence.reason AS evidence_reason,cycle,duration_ns,
 CASE WHEN update_ns>=render_callback_ns AND update_ns>=task_executor_ns AND update_ns>=host_other_ns THEN 'update'
      WHEN render_callback_ns>=task_executor_ns AND render_callback_ns>=host_other_ns THEN 'render_callback'
      WHEN task_executor_ns>=host_other_ns THEN 'task_executor_including_polling_or_pacing' ELSE 'host_other' END AS largest_measured_component
FROM evidence LEFT JOIN cycles ON evidence.status='complete' AND duration_ns>:budget_ns ORDER BY duration_ns DESC,cycle;
