SELECT CASE WHEN writer_failed=0 AND output_limited=0 AND omitted_events=0 THEN 'complete' ELSE 'degraded' END evidence_status,
       CASE WHEN writer_failed<>0 THEN 'writer failed' WHEN output_limited<>0 THEN 'output limit reached' WHEN omitted_events<>0 THEN 'recording contains omissions' ELSE 'recorder completed without loss' END evidence_reason,
       transactions,checkpoints,queue_high_water,output_bytes,omitted_events,writer_failed,output_limited,writer_cpu_ns FROM recorder_health WHERE id=1;
