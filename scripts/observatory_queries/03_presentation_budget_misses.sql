WITH evidence AS (SELECT c.status,CASE WHEN c.status<>'complete' THEN c.reason WHEN b.status<>'complete' THEN b.reason ELSE c.reason END reason,b.status backend_status FROM measurement_status c JOIN measurement_status b ON b.name='backend_facts' WHERE c.name='cycle_summary'),
pacing AS (SELECT value_b AS fps FROM gpu_facts WHERE kind=2 AND name='host_fps_cap' AND value_b>0 LIMIT 1)
SELECT CASE WHEN evidence.status='complete' AND backend_status='complete' AND EXISTS(SELECT 1 FROM pacing) THEN 'complete' ELSE 'unavailable' END AS evidence_status,
       CASE WHEN NOT EXISTS(SELECT 1 FROM pacing) THEN 'no enforceable numeric presentation budget recorded' ELSE evidence.reason END evidence_reason,
       CASE WHEN evidence.status='complete' AND backend_status='complete' AND EXISTS(SELECT 1 FROM pacing) THEN (SELECT count(*) FROM cycles,pacing WHERE duration_ns>1000000000/fps) END AS missed_cycles FROM evidence;
