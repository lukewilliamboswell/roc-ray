SELECT cycle,duration_ns,update_ns,render_ns,task_pump_ns FROM cycles ORDER BY duration_ns DESC,cycle LIMIT :limit;
