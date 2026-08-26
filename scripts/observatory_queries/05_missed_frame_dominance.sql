SELECT cycle,duration_ns,CASE WHEN update_ns>=render_ns AND update_ns>=task_pump_ns THEN 'update' WHEN render_ns>=task_pump_ns THEN 'render' ELSE 'task_pump' END AS dominant_component
FROM cycles WHERE duration_ns>:budget_ns ORDER BY duration_ns DESC,cycle;
