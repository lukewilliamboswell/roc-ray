SELECT subject_id,cycle,timestamp_ns,prior_bytes,bytes,copied_bytes,phase,task_id,zone_id FROM allocation_events WHERE kind IN (2,3) ORDER BY copied_bytes DESC,id;
